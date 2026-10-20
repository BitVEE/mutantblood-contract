// SPDX-License-Identifier: MIT
pragma solidity >= 0.8.19 < 0.9.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// MintSale：盲盒销售合约（纯付款模式）
//
// 改造说明：
//   - 不再在购买时直接 mint Role NFT
//   - buy() 只负责收取 USDC 并 emit event
//   - 后端监听 event_Purchase → 发放盲盒 → 用户开盒时走 WithdrawRoleModuleV1.withdrawRole()
//
// 默认参数：
//   - 价格：10 USDC/个（可调整）
//   - 限购：每个钱包最多 2 个（可调整）
//   - 总量：3000 个（可调整）
//   - 默认关闭售卖（需 Owner 开启）
//
// 流程：
//   1. Owner 开启售卖 setSaleActive(true)
//   2. 后端为购买请求生成 identificationID，EIP-712 签名
//   3. 前端 approve USDC → 调用 buy(quantity, identificationID, deadline, v, r, s)
//   4. 合约验签 → 转 USDC → emit event_Purchase
//   5. 后端监听 event → 发放盲盒 → 用户走 WithdrawRoleModuleV1 开盒
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
contract MintSale is EIP712
{
    using SafeERC20 for IERC20;

    event event_Purchase(
        address indexed buyer,
        uint64  indexed identificationID,
        uint256 quantity,
        uint256 totalPrice,
        uint256 nonce
    );

    event event_PurchaseItem(
        address indexed buyer,
        uint256 indexed itemID,
        uint64  indexed identificationID,
        uint256 quantity,
        uint256 totalPrice,
        uint256 nonce
    );

    bytes32 immutable private _BUY_TYPEHASH = keccak256(
        "Buy(address signer,address to,uint256 quantity,uint64 identificationID,uint64 deadline,uint256 nonce)"
    );

    bytes32 immutable private _BUY_ITEM_TYPEHASH = keccak256(
        "BuyItem(address signer,address to,uint256 itemID,uint256 quantity,uint256 totalPrice,uint64 identificationID,uint64 deadline,uint256 nonce)"
    );

    address private m_Owner;
    address private m_Signer;       // 后端签名钱包
    address private m_Receiver;     // USDC 收款钱包

    IERC20  private m_USDC;

    uint256  public  price        = 10 * 1e6;       // 10 USDC（6位小数）
    uint256  public  maxSupply    = 3000;
    uint256  public  maxPerWallet = 2;
    uint256  public  totalSold    = 0;
    bool     public  saleActive   = false;           // 默认关闭

    mapping(address => uint256) private m_Purchased;
    mapping(address => uint256) private m_Nonces;

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    constructor(
        address ownerAddr,
        address signerAddr,
        address receiverAddr,
        address usdcAddr
    ) EIP712("MintSale", "1")
    {
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
        require(msg.sender == m_Owner, "permission denied !");
        _;
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // 购买盲盒（只收钱 + 发事件，不 mint NFT）
    function buy(
        uint256 quantity,
        uint64  identificationID,
        uint64  deadline,
        uint8   v,
        bytes32 r,
        bytes32 s
    ) external {
        require(saleActive,                                    "sale not active");
        require(quantity > 0,                                  "quantity must > 0");
        require(block.timestamp <= deadline,                    "signature expired");
        require(totalSold + quantity <= maxSupply,              "exceeds max supply");
        require(m_Purchased[msg.sender] + quantity <= maxPerWallet, "exceeds per wallet limit");

        // EIP-712 验签
        uint256 nonce = m_Nonces[msg.sender]++;
        bytes32 structHash = keccak256(abi.encode(
            _BUY_TYPEHASH,
            m_Signer,
            msg.sender,
            quantity,
            identificationID,
            deadline,
            nonce
        ));
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), v, r, s);
        require(signer == m_Signer, "invalid signature");

        // 收取 USDC
        uint256 totalPrice = price * quantity;
        m_USDC.safeTransferFrom(msg.sender, m_Receiver, totalPrice);

        // 更新计数
        m_Purchased[msg.sender] += quantity;
        totalSold               += quantity;

    // 发事件（后端监听此事件，发放盲盒）
        emit event_Purchase(msg.sender, identificationID, quantity, totalPrice, nonce);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // 购买 Item（只收钱 + 发事件，后端签名决定定价和商品，不经过开关和限购检查）
    function buyItem(
        uint256 itemID,
        uint256 quantity,
        uint256 totalPrice,
        uint64  identificationID,
        uint64  deadline,
        uint8   v,
        bytes32 r,
        bytes32 s
    ) external {
        require(quantity > 0,                                   "quantity must > 0");
        require(block.timestamp <= deadline,                    "signature expired");

        // EIP-712 验签（TotalPrice包含在签名中，确保价格无法篡改）
        uint256 nonce = m_Nonces[msg.sender]++;
        bytes32 structHash = keccak256(abi.encode(
            _BUY_ITEM_TYPEHASH,
            m_Signer,
            msg.sender,
            itemID,
            quantity,
            totalPrice,
            identificationID,
            deadline,
            nonce
        ));
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), v, r, s);
        require(signer == m_Signer, "invalid signature");

        // 收取 USDC
        if (totalPrice > 0) {
            m_USDC.safeTransferFrom(msg.sender, m_Receiver, totalPrice);
        }

        // 发事件（后端监听此事件，发放 Item）
        emit event_PurchaseItem(msg.sender, itemID, identificationID, quantity, totalPrice, nonce);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // 查询
    function purchasedOf(address account) external view returns (uint256) {
        return m_Purchased[account];
    }

    function nonces(address account) external view returns (uint256) {
        return m_Nonces[account];
    }

    function remainingSupply() external view returns (uint256) {
        return maxSupply - totalSold;
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Owner 管理函数
    function setSaleActive(bool active) external onlyOwner {
        saleActive = active;
    }

    function setPrice(uint256 newPrice) external onlyOwner {
        price = newPrice;
    }

    function setMaxSupply(uint256 newMax) external onlyOwner {
        require(newMax >= totalSold, "max supply < already sold");
        maxSupply = newMax;
    }

    function setMaxPerWallet(uint256 newMax) external onlyOwner {
        maxPerWallet = newMax;
    }

    function setSigner(address addr) external onlyOwner {
        require(addr != address(0), "signer addr err");
        m_Signer = addr;
    }

    function setReceiver(address addr) external onlyOwner {
        require(addr != address(0), "receiver addr err");
        m_Receiver = addr;
    }

    function setOwner(address newAddr) external onlyOwner {
        require(newAddr != address(0), "owner addr err");
        m_Owner = newAddr;
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}
