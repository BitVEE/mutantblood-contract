// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19 <0.9.0;

import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "../interface/ITokenRole.sol";
import "../interface/ITokenItem.sol";

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// RoleUpgradeModuleV1：角色属性升级模块
//
// 包含两种操作，各自独立的 TypeHash、方法和 Event：
//   1. 洗炼 (refineRole)：消耗药水 Item → 整体替换 Role 属性
//   2. 镶嵌符文 (embedRune)：消耗符文 Item → 整体替换 Role 属性
//
// 安全性：EIP-712 + Nonce防重放 + Deadline过期 + Suspend紧急暂停
// 权限要求：
//   - 本合约需为 MutantBloodRole 的 GameAdmin（调用 batchChangeAttributes）
//   - 本合约需为 MutantBloodItem 的 Minter（调用 burn）
//   - 本合约需为 MutantBloodItem 的 AllowedOperator（玩家 approve 后 burn）
//   - 玩家需对 Item 合约 setApprovalForAll(thisModule, true)
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
contract RoleUpgradeModuleV1 is EIP712, ReentrancyGuard {
    // ── Events ──────────────────────────────────────────────────────────────────
    event event_RefineRole(
        address indexed owner,
        uint256 indexed roleTokenID,
        uint64 indexed identificationID,
        uint256[] burnItemIDs,
        uint256[] burnItemAmounts,
        bytes newAttributes
    );

    event event_EmbedRune(
        address indexed owner,
        uint256 indexed roleTokenID,
        uint64 indexed identificationID,
        uint256[] burnRuneIDs,
        uint256[] burnRuneAmounts,
        bytes newAttributes
    );

    // ── TypeHashes ──────────────────────────────────────────────────────────────
    bytes32 private immutable _REFINE_TYPEHASH =
        keccak256(
            "RefineRole(address signer,address to,uint256 roleTokenID,bytes32 itemsHash,bytes32 newAttributesHash,uint64 identificationID,uint64 deadline,uint256 nonce)"
        );

    bytes32 private immutable _EMBED_TYPEHASH =
        keccak256(
            "EmbedRune(address signer,address to,uint256 roleTokenID,bytes32 runesHash,bytes32 newAttributesHash,uint64 identificationID,uint64 deadline,uint256 nonce)"
        );

    // ── State ───────────────────────────────────────────────────────────────────
    address private m_Owner;
    address private m_Signer;
    bool private m_Suspend;

    ITokenRole private immutable m_TokenRole;
    ITokenItem private immutable m_TokenItem;

    mapping(address => uint256) private m_Nonces;

    // ── Constructor ─────────────────────────────────────────────────────────────
    constructor(
        address ownerAddr,
        address signerAddr,
        address roleTokenAddr,
        address itemTokenAddr
    ) EIP712("RoleUpgradeModuleV1", "1") {
        require(ownerAddr != address(0), "owner addr err");
        require(signerAddr != address(0), "signer addr err");
        require(roleTokenAddr != address(0), "role token addr err");
        require(itemTokenAddr != address(0), "item token addr err");

        m_Owner = ownerAddr;
        m_Signer = signerAddr;
        m_TokenRole = ITokenRole(roleTokenAddr);
        m_TokenItem = ITokenItem(itemTokenAddr);
        m_Suspend = false;
    }

    modifier onlyOwner() {
        require(m_Owner == msg.sender, "permission denied !");
        _;
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // 洗炼：销毁药水 Item → 整体替换 Role 属性
    function refineRole(
        uint256 roleTokenID,
        uint256[] calldata itemIDs,
        uint256[] calldata itemAmounts,
        bytes calldata newAttributes,
        uint64 identificationID,
        uint64 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant {
        require(!m_Suspend, "service suspended");
        require(block.timestamp <= deadline, "signature expired");
        require(itemIDs.length > 0, "items empty");
        require(itemIDs.length == itemAmounts.length, "items length mismatch");
        require(newAttributes.length > 0, "attributes empty");
        require(newAttributes.length % 4 == 0, "attributes length err");

        // 验证 Role 归属
        require(
            m_TokenRole.ownerOf(roleTokenID) == msg.sender,
            "not role owner"
        );

        // EIP-712 验签
        uint256 nonce = m_Nonces[msg.sender]++;
        bytes32 itemsHash = keccak256(abi.encodePacked(itemIDs, itemAmounts));
        bytes32 structHash = keccak256(
            abi.encode(
                _REFINE_TYPEHASH,
                m_Signer,
                msg.sender,
                roleTokenID,
                itemsHash,
                keccak256(newAttributes),
                identificationID,
                deadline,
                nonce
            )
        );
        require(
            ECDSA.recover(_hashTypedDataV4(structHash), v, r, s) == m_Signer,
            "invalid signature"
        );

        // 销毁药水
        for (uint256 i = 0; i < itemIDs.length; i++) {
            m_TokenItem.burn(msg.sender, itemIDs[i], itemAmounts[i]);
        }

        // 整体替换 Role 属性
        m_TokenRole.batchChangeAttributes(
            msg.sender,
            roleTokenID,
            newAttributes
        );

        emit event_RefineRole(
            msg.sender,
            roleTokenID,
            identificationID,
            itemIDs,
            itemAmounts,
            newAttributes
        );
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // 镶嵌符文：销毁符文 Item → 整体替换 Role 属性
    function embedRune(
        uint256 roleTokenID,
        uint256[] calldata runeIDs,
        uint256[] calldata runeAmounts,
        bytes calldata newAttributes,
        uint64 identificationID,
        uint64 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant {
        require(!m_Suspend, "service suspended");
        require(block.timestamp <= deadline, "signature expired");
        require(runeIDs.length > 0, "runes empty");
        require(runeIDs.length == runeAmounts.length, "runes length mismatch");
        require(newAttributes.length > 0, "attributes empty");
        require(newAttributes.length % 4 == 0, "attributes length err");

        // 验证 Role 归属
        require(
            m_TokenRole.ownerOf(roleTokenID) == msg.sender,
            "not role owner"
        );

        // EIP-712 验签
        uint256 nonce = m_Nonces[msg.sender]++;
        bytes32 runesHash = keccak256(abi.encodePacked(runeIDs, runeAmounts));
        bytes32 structHash = keccak256(
            abi.encode(
                _EMBED_TYPEHASH,
                m_Signer,
                msg.sender,
                roleTokenID,
                runesHash,
                keccak256(newAttributes),
                identificationID,
                deadline,
                nonce
            )
        );
        require(
            ECDSA.recover(_hashTypedDataV4(structHash), v, r, s) == m_Signer,
            "invalid signature"
        );

        // 销毁符文
        for (uint256 i = 0; i < runeIDs.length; i++) {
            m_TokenItem.burn(msg.sender, runeIDs[i], runeAmounts[i]);
        }

        // 整体替换 Role 属性
        m_TokenRole.batchChangeAttributes(
            msg.sender,
            roleTokenID,
            newAttributes
        );

        emit event_EmbedRune(
            msg.sender,
            roleTokenID,
            identificationID,
            runeIDs,
            runeAmounts,
            newAttributes
        );
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
