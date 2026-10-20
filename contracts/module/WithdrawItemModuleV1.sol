// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19 <0.9.0;

import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import "../interface/ITokenItem.sol";

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// WithdrawItemModuleV1：道具 NFT (ERC-1155) 提现模块
//
// 流程：
//   1. 玩家在游戏中获得道具掉落
//   2. 后端决定道具 ID 和数量，EIP-712 签名
//   3. 玩家钱包调用 withdrawItem()，合约验签并 mint 道具
//
// 注意：Item 是 ERC-1155，支持同一 ID 的多数量 mint
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
contract WithdrawItemModuleV1 is EIP712 {
    event event_WithdrawResult(
        address indexed ownerAddr,
        uint64 timestamp,
        uint64 indexed identificationID,
        uint256 itemID,
        uint256 amount
    );

    bytes32 private immutable _TYPEHASH =
        keccak256(
            "WithdrawItem(address signer,address to,uint256 itemID,uint256 amount,uint64 identificationID,uint64 deadline,uint256 nonce)"
        );

    address private m_Owner;
    address private m_Signer;
    bool private m_Suspend;

    ITokenItem private immutable m_TokenItem;
    mapping(address => uint256) private m_Nonces;

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    constructor(
        address ownerAddr,
        address signerAddr,
        address itemTokenAddr
    ) EIP712("WithdrawItemModuleV1", "1") {
        require(ownerAddr != address(0), "owner addr err");
        require(signerAddr != address(0), "signer addr err");
        require(itemTokenAddr != address(0), "item token addr err");

        m_Owner = ownerAddr;
        m_Signer = signerAddr;
        m_TokenItem = ITokenItem(itemTokenAddr);
        m_Suspend = false;
    }

    modifier onlyOwner() {
        require(m_Owner == msg.sender, "permission denied !");
        _;
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    function withdrawItem(
        uint256 itemID,
        uint256 amount,
        uint64 identificationID,
        uint64 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(!m_Suspend, "service suspended");
        require(block.timestamp <= deadline, "signature expired");
        require(amount > 0, "amount must > 0");

        uint256 nonce = m_Nonces[msg.sender]++;

        bytes32 structHash = keccak256(
            abi.encode(
                _TYPEHASH,
                m_Signer,
                msg.sender,
                itemID,
                amount,
                identificationID,
                deadline,
                nonce
            )
        );
        bytes32 hash = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(hash, v, r, s);
        require(signer == m_Signer, "invalid signature");

        m_TokenItem.mint(msg.sender, itemID, amount, "");

        emit event_WithdrawResult(
            msg.sender,
            uint64(block.timestamp),
            identificationID,
            itemID,
            amount
        );
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
