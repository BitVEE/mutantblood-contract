// SPDX-License-Identifier: MIT
pragma solidity >= 0.8.19 < 0.9.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// MarketContract：平台内 NFT 交易市场
//
// 规则：
//   - 所有 NFT 通过平台市场唯一流通（NFT 合约白名单保证）
//   - USDC 结算，固定 5% 版税给平台
//   - 支持 ERC-721 和 ERC-1155
//   - 卖家挂单后 NFT 锁仓在市场合约（escrow 模式）
//
// 使用流程：
//   卖家：setApprovalForAll(market, true) → list(...)
//   买家：approve USDC → buy(listingId)
//   卖家：可 cancel(listingId) 取消挂单
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
contract MarketContract is ReentrancyGuard, Pausable, EIP712
{
    using SafeERC20 for IERC20;

    enum NFTType { None, ERC721, ERC1155 }

    struct Listing {
        uint256  listingId;
        address  seller;
        address  tokenContract;
        uint256  tokenId;
        uint256  amount;     // ERC721 = 1
        uint256  price;      // USDC（6位小数）
        NFTType  nftType;
        bool     active;
    }

    event event_List(
        uint256 indexed listingId,
        address indexed seller,
        address         tokenContract,
        uint256 indexed tokenId,
        uint256         amount,
        uint256         price,
        NFTType         nftType,
        uint64          bizId
    );
    event event_Sale(
        uint256 indexed listingId,
        address indexed buyer,
        address         tokenContract,
        uint256         tokenId,
        uint256         price,
        uint256         royalty,
        uint64          bizId
    );
    event event_Cancel(uint256 indexed listingId, address indexed seller, uint64 bizId);
    event event_RoyaltyReceiverChanged(address indexed previousReceiver, address indexed newReceiver);
    event event_USDCChanged(address indexed previousUSDC, address indexed newUSDC);

    event event_PayOffchainOrder(
        uint64  indexed bizId,
        uint64          orderId,
        address indexed buyer,
        address indexed seller,
        uint256 price,
        uint256 royalty
    );
    uint256 public m_RoyaltyBPS = 500;   // 5%（500/10000）

    address  private m_Owner;
    address  private m_RoyaltyReceiver;
    IERC20   private m_USDC;

    address  private m_Signer;
    mapping(address => uint256) public nonces;

    mapping(address => bool)    private m_AllowedNFT;    // 白名单 NFT 合约
    mapping(uint256 => Listing) private m_Listings;
    uint256 private m_NextListingId = 1;

    bytes32 private immutable _PAY_TYPEHASH = keccak256(
        "PayOffchainOrder(address seller,address buyer,uint64 bizId,uint64 orderId,uint256 price,uint64 deadline,uint256 nonce)"
    );

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    constructor(address ownerAddr, address royaltyReceiver, address usdcAddr, address signerAddr)
        EIP712("MarketContract", "1")
    {
        require(ownerAddr        != address(0), "owner addr err");
        require(royaltyReceiver  != address(0), "royalty addr err");
        require(usdcAddr         != address(0), "usdc addr err");
        require(signerAddr       != address(0), "signer addr err");

        m_Owner           = ownerAddr;
        m_RoyaltyReceiver = royaltyReceiver;
        m_USDC            = IERC20(usdcAddr);
        m_Signer          = signerAddr;
    }

    modifier onlyOwner() {
        require(msg.sender == m_Owner, "permission denied !");
        _;
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // 挂单（NFT 从卖家锁仓到本合约）
    function list(
        address tokenContract,
        uint256 tokenId,
        uint256 amount,
        uint256 price,
        NFTType nftType,
        uint64 bizId
    ) external whenNotPaused returns (uint256 listingId)
    {
        require(m_AllowedNFT[tokenContract], "NFT not allowed");
        require(price > 0,                   "price must > 0");

        if (nftType == NFTType.ERC721) {
            require(amount == 1, "ERC721 amount must be 1");
            require(IERC721(tokenContract).ownerOf(tokenId) == msg.sender, "not token owner");
            IERC721(tokenContract).safeTransferFrom(msg.sender, address(this), tokenId);
        } else {
            require(amount > 0, "amount must > 0");
            IERC1155(tokenContract).safeTransferFrom(msg.sender, address(this), tokenId, amount, "");
        }

        listingId = m_NextListingId++;
        m_Listings[listingId] = Listing({
            listingId:     listingId,
            seller:        msg.sender,
            tokenContract: tokenContract,
            tokenId:       tokenId,
            amount:        amount,
            price:         price,
            nftType:       nftType,
            active:        true
        });

        emit event_List(listingId, msg.sender, tokenContract, tokenId, amount, price, nftType, bizId);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // 购买（USDC 分配：5% 给平台，95% 给卖家，NFT 转给买家）
    function buy(uint256 listingId, uint64 bizId) external nonReentrant whenNotPaused
    {
        Listing storage l = m_Listings[listingId];
        require(l.active,               "listing not active");
        require(l.seller != msg.sender, "cannot buy own listing");

        l.active = false;  // 先标记无效（防重入）

        uint256 royalty    = l.price * m_RoyaltyBPS / 10000;
        uint256 sellerGets = l.price - royalty;

        // USDC 分配
        m_USDC.safeTransferFrom(msg.sender, m_RoyaltyReceiver, royalty);
        m_USDC.safeTransferFrom(msg.sender, l.seller, sellerGets);

        // NFT 转给买家
        if (l.nftType == NFTType.ERC721) {
            IERC721(l.tokenContract).safeTransferFrom(address(this), msg.sender, l.tokenId);
        } else {
            IERC1155(l.tokenContract).safeTransferFrom(address(this), msg.sender, l.tokenId, l.amount, "");
        }

        emit event_Sale(listingId, msg.sender, l.tokenContract, l.tokenId, l.price, royalty, bizId);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // 购买链下资产订单（血瓶等）
    function payOffchainOrder(
        address seller,
        uint64  bizId,
        uint64  orderId,
        uint256 price,
        uint64  deadline,
        uint8 v, bytes32 r, bytes32 s
    ) external nonReentrant whenNotPaused {
        require(price > 0, "price > 0");
        require(block.timestamp <= deadline, "signature expired");
        require(msg.sender != seller, "cannot buy from yourself");

        uint256 nonce = nonces[msg.sender]++;
        bytes32 structHash = keccak256(abi.encode(
            _PAY_TYPEHASH,
            seller,
            msg.sender,
            bizId,
            orderId,
            price,
            deadline,
            nonce
        ));
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), v, r, s);
        require(signer == m_Signer, "invalid signature");

        uint256 royalty    = price * m_RoyaltyBPS / 10000;
        uint256 sellerGets = price - royalty;

        m_USDC.safeTransferFrom(msg.sender, m_RoyaltyReceiver, royalty);
        m_USDC.safeTransferFrom(msg.sender, seller, sellerGets);

        emit event_PayOffchainOrder(bizId, orderId, msg.sender, seller, price, royalty);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // 取消挂单（退还 NFT 给卖家）
    function cancel(uint256 listingId, uint64 bizId) external nonReentrant
    {
        Listing storage l = m_Listings[listingId];
        require(l.active,              "listing not active");
        require(l.seller == msg.sender, "not listing owner");

        l.active = false;

        if (l.nftType == NFTType.ERC721) {
            IERC721(l.tokenContract).safeTransferFrom(address(this), msg.sender, l.tokenId);
        } else {
            IERC1155(l.tokenContract).safeTransferFrom(address(this), msg.sender, l.tokenId, l.amount, "");
        }

        emit event_Cancel(listingId, msg.sender, bizId);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // 查询
    function getListing(uint256 listingId) external view returns (Listing memory) {
        return m_Listings[listingId];
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Owner 管理
    function setAllowedNFT(address tokenContract, bool allowed) external onlyOwner {
        m_AllowedNFT[tokenContract] = allowed;
    }

    function setRoyaltyReceiver(address addr) external onlyOwner {
        require(addr != address(0), "royalty addr err");
        address previousReceiver = m_RoyaltyReceiver;
        m_RoyaltyReceiver = addr;
        emit event_RoyaltyReceiverChanged(previousReceiver, addr);
    }

    function getRoyaltyReceiver() external view returns (address) {
        return m_RoyaltyReceiver;
    }

    function setRoyaltyBPS(uint256 newBPS) external onlyOwner {
        require(newBPS <= 10000, "BPS > 10000");
        m_RoyaltyBPS = newBPS;
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

    function setSigner(address newAddr) external onlyOwner {
        require(newAddr != address(0), "signer addr err");
        m_Signer = newAddr;
    }

    function getSigner() external view returns(address) {
        return m_Signer;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // 安全：接收 NFT 回调
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }
}
