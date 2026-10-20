// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19 <0.9.0;

import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import "../interface/ITokenRole.sol";

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// WithdrawRoleModuleV1：角色 NFT 提现模块
//
// 流程：
//   1. 玩家在游戏中获得角色掉落/奖励
//   2. 后端计算角色属性，EIP-712 签名
//   3. 玩家钱包调用 withdrawRole()，合约验签并 mint 角色 NFT
//
// 安全性：EIP-712 + Nonce防重放 + Deadline过期 + Suspend紧急暂停
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
contract WithdrawRoleModuleV1 is EIP712 {
    event event_WithdrawResult(
        address indexed ownerAddr,
        uint64 timestamp,
        uint64 indexed identificationID,
        uint256 indexed tokenID
    );

    bytes32 private immutable _TYPEHASH =
        keccak256(
            "WithdrawRole(address signer,address to,uint32 version,uint64 characteristics,bytes attributes,uint64 identificationID,uint64 deadline,uint256 nonce)"
        );

    address private m_Owner;
    address private m_Signer;
    bool private m_Suspend;

    ITokenRole private immutable m_TokenRole;
    mapping(address => uint256) private m_Nonces;

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    constructor(
        address ownerAddr,
        address signerAddr,
        address roleTokenAddr
    ) EIP712("WithdrawRoleModuleV1", "1") {
        require(ownerAddr != address(0), "owner addr err");
        require(signerAddr != address(0), "signer addr err");
        require(roleTokenAddr != address(0), "role token addr err");

        m_Owner = ownerAddr;
        m_Signer = signerAddr;
        m_TokenRole = ITokenRole(roleTokenAddr);
        m_Suspend = false;
    }

    modifier onlyOwner() {
        require(m_Owner == msg.sender, "permission denied !");
        _;
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    function withdrawRole(
        uint32 version,
        uint64 characteristics,
        bytes calldata attributes,
        uint64 identificationID,
        uint64 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256) {
        require(!m_Suspend, "service suspended");
        require(block.timestamp <= deadline, "signature expired");
        require(attributes.length > 0, "attributes empty");
        require(attributes.length % 4 == 0, "attributes length err");

        uint256 nonce = m_Nonces[msg.sender]++;

        bytes32 structHash = keccak256(
            abi.encode(
                _TYPEHASH,
                m_Signer,
                msg.sender,
                version,
                characteristics,
                keccak256(attributes),
                identificationID,
                deadline,
                nonce
            )
        );
        bytes32 hash = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(hash, v, r, s);
        require(signer == m_Signer, "invalid signature");

        uint256 tokenID = m_TokenRole.mint(
            msg.sender,
            version,
            characteristics,
            attributes
        );

        emit event_WithdrawResult(
            msg.sender,
            uint64(block.timestamp),
            identificationID,
            tokenID
        );
        return tokenID;
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
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
