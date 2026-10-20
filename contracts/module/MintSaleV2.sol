// SPDX-License-Identifier: MIT
pragma solidity >= 0.8.19 < 0.9.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../interface/ITokenItem.sol";

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// MintSaleV2：灵活商品销售合约
//
// 支持的商品类型 (ProductType)：
//   HERO_BOX     — 英雄盲盒，纯支付，通知后端发放盲盒。英雄类共享单地址总限购。
//   PET_BOX      — 宠物盲盒，纯支付，通知后端发放盲盒。
//   ITEM_NOTIFY  — 道具（纯支付），通知后端在中心化库更新数据。
//   ITEM_MINT    — 道具（直接链上 mint ERC1155），需要 MintSaleV2 有 item 合约的 minter 权限。
//
// 英雄限购：
//   所有 HERO_BOX 类型的产品共享 maxHeroPerWallet 限制（跨所有英雄种类累计）
//   其他类型的商品可在 Product.maxPerWallet 中独立设置，0 = 不限
//
// Owner 管理：
//   addProduct         — 新增商品（productId 由 owner 自由指定，方便与后端约定）
//   setProductActive   — 开关（不删除数据，sold 计数不重置）
//   setProductPrice    — 改价
//   addProductSupply   — 加库存（增加 maxSupply）
//   setProductStage    — 原子更新价格和当前阶段精确可售数量
//   setMaxHeroPerWallet— 修改英雄共享限购
//
// EIP-712 签名：
//   后端签名包含 productId + quantity，价格由合约读链上值，防止前端篡改
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
contract MintSaleV2 is EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── 商品类型 ──────────────────────────────────────────────────────────────
    enum ProductType {
        HERO_BOX,       // 0: 英雄盲盒（纯支付 → 后端发盲盒）
        PET_BOX,        // 1: 宠物盲盒（纯支付 → 后端发盲盒）
        ITEM_NOTIFY,    // 2: 道具（纯支付 → 后端更新中心化库）
        ITEM_MINT       // 3: 道具（直接链上 mint ERC1155）
    }

    // ── 商品信息 ──────────────────────────────────────────────────────────────
    struct Product {
        uint32      productId;      // 商品唯一 ID（例如 70001=初级英雄盲盒）
        ProductType productType;    // 商品类型
        uint256     price;          // 支付代币最小单位计价
        uint32      maxSupply;      // 总供应量上限（0 = 不限）
        uint32      sold;           // 已售出数量（只增不减，即使关闭再开启也累计）
        uint32      maxPerWallet;   // 单地址购买上限（仅对非英雄类有效，0 = 不限）
        bool        active;         // 是否开启销售
        // ITEM_MINT 专用字段
        address     itemContract;   // ERC1155 合约地址（其他类型填 address(0)）
        uint256     itemId;         // ERC1155 token id（其他类型填 0）
        uint32      dailyLimit;     // 单地址每日购买上限（0 = 不限）
    }

    // ── Events ────────────────────────────────────────────────────────────────
    // 纯支付类通知事件（HERO_BOX / PET_BOX / ITEM_NOTIFY）
    event event_Purchase(
        address indexed buyer,
        uint32  indexed productId,
        uint64  indexed bizId,       // identificationID，后端用于关联业务记录
        uint256 quantity,
        uint256 totalPrice,
        uint256 nonce
    );

    // 直接链上 mint 类事件（ITEM_MINT）
    event event_PurchaseMint(
        address indexed buyer,
        uint32  indexed productId,
        uint64  indexed bizId,
        uint256 itemId,
        uint256 quantity,
        uint256 totalPrice,
        uint256 nonce
    );

    // 管理事件（用于前端/后端监听配置变化）
    event event_ProductAdded(uint32 indexed productId, ProductType productType, uint256 price, uint32 maxSupply);
    event event_ProductUpdated(uint32 indexed productId, string field, uint256 value);
    event event_ReceiverChanged(address indexed previousReceiver, address indexed newReceiver);
    event event_USDCChanged(address indexed previousUSDC, address indexed newUSDC);

    // ── TypeHash ──────────────────────────────────────────────────────────────
    bytes32 private immutable _BUY_TYPEHASH = keccak256(
        "Buy(address signer,address to,uint32 productId,uint256 quantity,uint64 bizId,uint64 deadline,uint256 nonce)"
    );

    // ── 存储 ──────────────────────────────────────────────────────────────────
    address private m_Owner;
    address private m_Signer;
    address private m_Receiver;   // USDC 收款地址
    IERC20  private m_USDC;

    // 英雄共享限购
    uint32  public  maxHeroPerWallet = 2;
    mapping(address => uint32) public heroTotalPurchased;

    // 商品存储
    mapping(uint32 => Product)  private m_Products;
    uint32[]                    private m_ProductIds;   // 用于枚举

    // 非英雄商品的单地址购买计数
    mapping(uint32 => mapping(address => uint32)) private m_ProductPurchased;

    // 防重放 Nonce
    mapping(address => uint256) private m_Nonces;

    // 时区偏移秒数（例如北京时间 UTC+8 填 28800，西五区填 -18000，默认为 0）
    int32   public  timeOffset;

    // 每日购买限制状态
    struct DailyLimitState {
        uint32 lastUpdateDay;  // 上次购买时的 Day ID
        uint32 purchasedToday; // 当天已购累计数量
    }
    // productId => buyer => DailyLimitState
    mapping(uint32 => mapping(address => DailyLimitState)) private m_DailyPurchases;

    bool public suspended = false;  // 全局紧急暂停

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    constructor(
        address ownerAddr,
        address signerAddr,
        address receiverAddr,
        address usdcAddr
    ) EIP712("MintSaleV2", "1") {
        require(ownerAddr    != address(0), "owner addr err");
        require(signerAddr   != address(0), "signer addr err");
        require(receiverAddr != address(0), "receiver addr err");
        require(usdcAddr     != address(0), "usdc addr err");

        m_Owner    = ownerAddr;
        m_Signer   = signerAddr;
        m_Receiver = receiverAddr;
        m_USDC     = IERC20(usdcAddr);
    }

    modifier onlyOwner() {
        require(msg.sender == m_Owner, "permission denied");
        _;
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // 核心购买函数
    function buy(
        uint32  productId,
        uint256 quantity,
        uint64  bizId,        // identificationID（后端生成的业务唯一ID）
        uint64  deadline,
        uint8   v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant {
        require(!suspended, "service suspended");
        require(quantity > 0, "quantity must > 0");
        require(block.timestamp <= deadline, "signature expired");

        Product storage product = m_Products[productId];
        require(product.productId != 0, "product not exist");
        require(product.active, "product not active");
        require(
            product.maxSupply == 0 || product.sold + uint32(quantity) <= product.maxSupply,
            "exceeds max supply"
        );

        // 英雄类：共享跨产品的单地址限购
        if (product.productType == ProductType.HERO_BOX) {
            require(
                heroTotalPurchased[msg.sender] + uint32(quantity) <= maxHeroPerWallet,
                "exceeds hero per wallet limit"
            );
        }
        // 非英雄类：检查各自的 maxPerWallet
        else if (product.maxPerWallet > 0) {
            require(
                m_ProductPurchased[productId][msg.sender] + uint32(quantity) <= product.maxPerWallet,
                "exceeds per wallet limit"
            );
        }

        // 每日限购校验与更新
        if (product.dailyLimit > 0) {
            uint32 currentDay = uint32(uint256(int256(block.timestamp) + timeOffset) / 86400);
            DailyLimitState storage state = m_DailyPurchases[productId][msg.sender];
            
            uint32 purchasedToday = 0;
            if (state.lastUpdateDay == currentDay) {
                purchasedToday = state.purchasedToday;
            }
            
            require(purchasedToday + uint32(quantity) <= product.dailyLimit, "exceeds daily limit");
            
            state.lastUpdateDay = currentDay;
            state.purchasedToday = purchasedToday + uint32(quantity);
        }

        // EIP-712 验签
        uint256 nonce = m_Nonces[msg.sender]++;
        bytes32 structHash = keccak256(abi.encode(
            _BUY_TYPEHASH,
            m_Signer,
            msg.sender,
            productId,
            quantity,
            bizId,
            deadline,
            nonce
        ));
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), v, r, s);
        require(signer == m_Signer, "invalid signature");

        // 收取支付代币
        uint256 totalPrice = product.price * quantity;
        if (totalPrice > 0) {
            m_USDC.safeTransferFrom(msg.sender, m_Receiver, totalPrice);
        }

        // 更新计数
        product.sold += uint32(quantity);
        if (product.productType == ProductType.HERO_BOX) {
            heroTotalPurchased[msg.sender] += uint32(quantity);
        } else {
            m_ProductPurchased[productId][msg.sender] += uint32(quantity);
        }

        // 根据产品类型执行不同操作
        if (product.productType == ProductType.ITEM_MINT) {
            // 直接链上 mint ERC1155
            require(product.itemContract != address(0), "item contract not set");
            ITokenItem(product.itemContract).mint(msg.sender, product.itemId, quantity, "");
            emit event_PurchaseMint(msg.sender, productId, bizId, product.itemId, quantity, totalPrice, nonce);
        } else {
            // HERO_BOX / PET_BOX / ITEM_NOTIFY：纯支付，发事件通知后端
            emit event_Purchase(msg.sender, productId, bizId, quantity, totalPrice, nonce);
        }
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // 查询函数

    function getProduct(uint32 productId) external view returns (Product memory) {
        require(m_Products[productId].productId != 0, "product not exist");
        return m_Products[productId];
    }

    function getAllProducts() external view returns (Product[] memory) {
        Product[] memory result = new Product[](m_ProductIds.length);
        for (uint256 i = 0; i < m_ProductIds.length; i++) {
            result[i] = m_Products[m_ProductIds[i]];
        }
        return result;
    }

    function remainingSupply(uint32 productId) external view returns (uint32) {
        Product storage p = m_Products[productId];
        if (p.maxSupply == 0) return type(uint32).max; // 无限
        return p.maxSupply - p.sold;
    }

    function purchasedOf(uint32 productId, address account) external view returns (uint32) {
        return m_ProductPurchased[productId][account];
    }

    /**
     * @notice 获取某个地址针对某商品在今日已购买的数量和剩余可购买数量
     * @return purchasedCount 今日已购买数量
     * @return remainingLimit 今日还能购买的数量（若无限制，返回 type(uint32).max）
     */
    function getDailyRemaining(uint32 productId, address account) 
        external 
        view 
        returns (uint32 purchasedCount, uint32 remainingLimit) 
    {
        Product storage product = m_Products[productId];
        if (product.productId == 0) return (0, 0);
        if (product.dailyLimit == 0) return (0, type(uint32).max);

        uint32 currentDay = uint32(uint256(int256(block.timestamp) + timeOffset) / 86400);
        DailyLimitState storage state = m_DailyPurchases[productId][account];

        if (state.lastUpdateDay == currentDay) {
            purchasedCount = state.purchasedToday;
        } else {
            purchasedCount = 0;
        }

        if (purchasedCount >= product.dailyLimit) {
            remainingLimit = 0;
        } else {
            remainingLimit = product.dailyLimit - purchasedCount;
        }
    }

    function nonces(address account) external view returns (uint256) {
        return m_Nonces[account];
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Owner 管理函数

    /**
     * @notice 新增商品
     * @param productId    商品 ID（由 owner 自由指定，建议与后端约定好，例如 70001=初级英雄盲盒）
     * @param productType  商品类型（0=HERO_BOX, 1=PET_BOX, 2=ITEM_NOTIFY, 3=ITEM_MINT）
     * @param price        支付代币最小单位计价
     * @param maxSupply    总库存上限（0 = 不限）
     * @param maxPerWallet 单地址限购（仅非英雄类有效，0 = 不限）
     * @param dailyLimit   单地址每日购买上限（0 = 不限）
     * @param itemContract ITEM_MINT 专用：ERC1155 合约地址（其他类型填 address(0)）
     * @param itemId       ITEM_MINT 专用：ERC1155 token id（其他类型填 0）
     */
    function addProduct(
        uint32      productId,
        ProductType productType,
        uint256     price,
        uint32      maxSupply,
        uint32      maxPerWallet,
        uint32      dailyLimit,
        address     itemContract,
        uint256     itemId
    ) external onlyOwner {
        require(productId != 0, "productId must > 0");
        require(m_Products[productId].productId == 0, "productId already exists");
        require(price > 0, "price must > 0");

        if (productType == ProductType.ITEM_MINT) {
            require(itemContract != address(0), "item contract required for ITEM_MINT");
        }

        m_Products[productId] = Product({
            productId:    productId,
            productType:  productType,
            price:        price,
            maxSupply:    maxSupply,
            sold:         0,
            maxPerWallet: maxPerWallet,
            active:       false,        // 默认关闭，需要手动开启
            itemContract: itemContract,
            itemId:       itemId,
            dailyLimit:   dailyLimit
        });
        m_ProductIds.push(productId);

        emit event_ProductAdded(productId, productType, price, maxSupply);
    }

    function setProductActive(uint32 productId, bool active) external onlyOwner {
        require(m_Products[productId].productId != 0, "product not exist");
        m_Products[productId].active = active;
        emit event_ProductUpdated(productId, "active", active ? 1 : 0);
    }

    function setProductPrice(uint32 productId, uint256 newPrice) external onlyOwner {
        require(m_Products[productId].productId != 0, "product not exist");
        require(newPrice > 0, "price must > 0");
        m_Products[productId].price = newPrice;
        emit event_ProductUpdated(productId, "price", newPrice);
    }

    /**
     * @notice 原子更新阶段价格和当前阶段精确可售数量
     * @dev maxSupply 会设置为累计已售数量加 availableSupply，因此可增加或减少库存，且不会低于 sold。
     */
    function setProductStage(
        uint32 productId,
        uint256 newPrice,
        uint32 availableSupply
    ) external onlyOwner {
        Product storage product = m_Products[productId];
        require(product.productId != 0, "product not exist");
        require(newPrice > 0, "price must > 0");

        uint32 newMaxSupply = product.sold + availableSupply;
        require(newMaxSupply > 0, "max supply must > 0");

        product.price = newPrice;
        product.maxSupply = newMaxSupply;
        emit event_ProductUpdated(productId, "price", newPrice);
        emit event_ProductUpdated(productId, "maxSupply", newMaxSupply);
    }

    /**
     * @notice 加库存（只能增加）
     */
    function addProductSupply(uint32 productId, uint32 amount) external onlyOwner {
        require(m_Products[productId].productId != 0, "product not exist");
        require(amount > 0, "amount must > 0");
        m_Products[productId].maxSupply += amount;
        emit event_ProductUpdated(productId, "maxSupply", m_Products[productId].maxSupply);
    }

    function setMaxHeroPerWallet(uint32 newMax) external onlyOwner {
        require(newMax > 0, "max must > 0");
        maxHeroPerWallet = newMax;
    }

    function setTimeOffset(int32 newOffset) external onlyOwner {
        timeOffset = newOffset;
        emit event_ProductUpdated(0, "timeOffset", uint256(int256(newOffset)));
    }

    function setProductDailyLimit(uint32 productId, uint32 dailyLimit) external onlyOwner {
        require(m_Products[productId].productId != 0, "product not exist");
        m_Products[productId].dailyLimit = dailyLimit;
        emit event_ProductUpdated(productId, "dailyLimit", dailyLimit);
    }

    function setSuspend(bool s) external onlyOwner {
        suspended = s;
    }

    function setSigner(address addr) external onlyOwner {
        require(addr != address(0), "signer addr err");
        m_Signer = addr;
    }

    function setReceiver(address addr) external onlyOwner {
        require(addr != address(0), "receiver addr err");
        address previousReceiver = m_Receiver;
        m_Receiver = addr;
        emit event_ReceiverChanged(previousReceiver, addr);
    }

    function getReceiver() external view returns (address) {
        return m_Receiver;
    }

    function setUSDC(address addr) external onlyOwner {
        require(addr != address(0), "usdc addr err");
        address previousUSDC = address(m_USDC);
        m_USDC = IERC20(addr);
        emit event_USDCChanged(previousUSDC, addr);
    }

    function getUSDC() external view returns (address) {
        return address(m_USDC);
    }

    function setOwner(address newAddr) external onlyOwner {
        require(newAddr != address(0), "owner addr err");
        m_Owner = newAddr;
    }
}
