// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19 <0.9.0;

import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import "../definition/MutantBloodDefine_Part.sol";
import "../interface/ITokenPart.sol";

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// WithdrawPartModuleV1：零件提现模块
//
// 流程：
//   1. 玩家游戏内获得零件掉落，游戏后端计算属性
//   2. 后端 EIP-712 签名 (to, partDisplay, partType, partQuality, attributes, identificationID, deadline, nonce)
//   3. 玩家钱包调用 withdrawPart()，合约验签并 mint 零件 NFT
//
// 安全性：
//   - EIP-712 结构化签名，防中间人伪造
//   - Nonce 防重放
//   - Deadline 防无限期有效签名
//   - Suspend 紧急暂停
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
contract WithdrawPartModuleV1 is EIP712 {
    event event_WithdrawResult(
        address indexed ownerAddr,
        uint64 timestamp,
        uint64 indexed identificationID,
        uint256 indexed tokenID
    );

    // EIP-712 type hash（含零件所有属性，后端完整签名）
    bytes32 private immutable _TYPEHASH =
        keccak256(
            "WithdrawPart(address signer,address to,uint8 display,uint8 partType,uint8 quality,bytes attributes,uint64 identificationID,uint64 deadline,uint256 nonce)"
        );

    address private m_Owner;
    address private m_Signer;
    bool private m_Suspend;

    ITokenPart private immutable m_TokenPart;
    mapping(address => uint256) private m_Nonces;

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    constructor(
        address ownerAddr,
        address signerAddr,
        address partTokenAddr
    ) EIP712("WithdrawPartModuleV1", "1") {
        require(ownerAddr != address(0), "owner addr err");
        require(signerAddr != address(0), "signer addr err");
        require(partTokenAddr != address(0), "part token addr err");

        m_Owner = ownerAddr;
        m_Signer = signerAddr;
        m_TokenPart = ITokenPart(partTokenAddr);
        m_Suspend = false;
    }

    modifier onlyOwner() {
        require(m_Owner == msg.sender, "permission denied !");
        _;
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // 主接口：玩家调用，参数全部由后端提供并签名
    function withdrawPart(
        uint8 display,
        uint8 partType,
        uint8 quality,
        bytes calldata attributes,
        uint64 identificationID,
        uint64 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256) {
        require(!m_Suspend, "WP01: service suspended");
        require(block.timestamp <= deadline, "WP02: signature expired");
        require(attributes.length > 0, "WP03: attributes empty");
        require(attributes.length % 4 == 0, "WP04: attributes length err");
        require(
            partType >= PART_TYPE_WEAPON && partType <= PART_TYPE_HEADGEAR,
            "WP05: part type err"
        );
        require(quality <= MAX_PART_QUALITY, "WP06: quality err");

        // 使用并增加 nonce（防重放）
        uint256 nonce = m_Nonces[msg.sender]++;

        // EIP-712 验签
        bytes32 structHash = keccak256(
            abi.encode(
                _TYPEHASH,
                m_Signer,
                msg.sender,
                display,
                partType,
                quality,
                keccak256(attributes), // bytes 类型用 keccak256 后编码
                identificationID,
                deadline,
                nonce
            )
        );
        bytes32 hash = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(hash, v, r, s);
        require(signer == m_Signer, "WP07: invalid signature");

        // 构造 Part struct 并 mint
        Part memory newPart = Part({
            TokenID: 0, // mint 时由合约分配
            TokenOwner: msg.sender,
            Display: display,
            Type: partType,
            Quality: quality,
            Attributes: attributes
        });

        uint256 tokenId = m_TokenPart.mint(newPart);

        // 获取 mint 出的 tokenID
        emit event_WithdrawResult(
            msg.sender,
            uint64(block.timestamp),
            identificationID,
            tokenId
        );

        return tokenId;
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // 管理函数
    function setSigner(address addr) external onlyOwner {
        require(addr != address(0), "signer address err !");
        m_Signer = addr;
    }

    function setSuspend(bool s) external onlyOwner {
        m_Suspend = s;
    }

    function setOwner(address newAddr) external onlyOwner {
        require(newAddr != address(0), "owner address err !");
        m_Owner = newAddr;
    }

    function nonces(address owner) external view returns (uint256) {
        return m_Nonces[owner];
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function getSigner() external view returns (address) {
        return m_Signer;
    }
}
