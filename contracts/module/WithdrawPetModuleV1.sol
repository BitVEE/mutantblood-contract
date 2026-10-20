// SPDX-License-Identifier: MIT
pragma solidity >= 0.8.19 < 0.9.0;

import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import "../interface/ITokenPet.sol";

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// WithdrawPetModuleV1：宠物 NFT 提现模块
//
// 流程：
//   1. 玩家在游戏中获得宠物掉落/孵化
//   2. 后端计算宠物属性，EIP-712 签名
//   3. 玩家钱包调用 withdrawPet()，合约验签并 mint 宠物 NFT
//
// 简化：Pet 的技能/属性统一用 bytes attributes 传递，签名中对 attributes 做 keccak256 摘要
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
contract WithdrawPetModuleV1 is EIP712
{
    event event_WithdrawResult(
        address indexed ownerAddr,
        uint64  timestamp,
        uint64  indexed identificationID,
        uint256 indexed tokenID
    );

    bytes32 immutable private _TYPEHASH = keccak256(
        "WithdrawPet(address signer,address to,uint256 petID,bytes attributes,uint64 identificationID,uint64 deadline,uint256 nonce)"
    );

    address private m_Owner;
    address private m_Signer;
    bool    private m_Suspend;

    ITokenPet private immutable m_TokenPet;
    mapping(address => uint256) private m_Nonces;

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    constructor(address ownerAddr, address signerAddr, address petTokenAddr)
        EIP712("WithdrawPetModuleV1", "1")
    {
        require(ownerAddr != address(0),    "owner addr err");
        require(signerAddr != address(0),   "signer addr err");
        require(petTokenAddr != address(0), "pet token addr err");

        m_Owner    = ownerAddr;
        m_Signer   = signerAddr;
        m_TokenPet = ITokenPet(petTokenAddr);
        m_Suspend  = false;
    }

    modifier onlyOwner() {
        require(m_Owner == msg.sender, "permission denied !");
        _;
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    function withdrawPet(
        uint256 petID,
        bytes   calldata attributes,
        uint64  identificationID,
        uint64  deadline,
        uint8   v,
        bytes32 r,
        bytes32 s
    ) external returns(uint256)
    {
        require(!m_Suspend,                  "service suspended");
        require(block.timestamp <= deadline,  "signature expired");

        uint256 nonce = m_Nonces[msg.sender]++;

        bytes32 structHash = keccak256(abi.encode(
            _TYPEHASH,
            m_Signer,
            msg.sender,
            petID,
            keccak256(attributes),
            identificationID,
            deadline,
            nonce
        ));
        bytes32 hash   = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(hash, v, r, s);
        require(signer == m_Signer, "invalid signature");

        uint256 tokenID = m_TokenPet.mint(msg.sender, petID, attributes);

        emit event_WithdrawResult(msg.sender, uint64(block.timestamp), identificationID, tokenID);
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
