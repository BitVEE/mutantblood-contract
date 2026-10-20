// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19 <0.9.0;

import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "../interface/ITokenRole.sol";
import "../interface/ITokenPart.sol";
import "../interface/ITokenPet.sol";
import "../interface/ITokenItem.sol";

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// CraftModuleV1：NFT 合成升级模块
//
// 前置权限：
//   - 本合约需为各 NFT 合约的 GameAdmin（用于 mint/burn）
//   - 本合约需为各 NFT 合约的 AllowedOperator（用于转移）
//   - 玩家需对本合约 setApprovalForAll(craftModule, true)
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
contract CraftModuleV1 is EIP712, ReentrancyGuard {
    event event_Craft(
        address indexed crafter,
        uint64 indexed identificationID,
        uint256 newTokenId
    );

    struct BurnItem {
        address tokenContract;
        uint256 tokenId;
        uint256 amount;
        uint8 nftType; // 1=ERC721  2=ERC1155
    }

    // 合成结果描述（精简为最必要字段）
    struct MintInfo {
        uint8 nftType; // 1=Role 2=Part 3=Pet 4=Item
        uint32 version; // Role
        uint64 characteristics; // Role
        bytes attributes; // Role/Part
        uint8 display; // Part
        uint8 partType; // Part
        uint8 quality; // Part
        uint256 petId; // Pet
        uint256 itemId; // Item
        uint256 itemAmount; // Item
    }

    bytes32 private immutable _BURN_TYPEHASH =
        keccak256(
            "BurnItem(address tokenContract,uint256 tokenId,uint256 amount,uint8 nftType)"
        );
    bytes32 private immutable _TYPEHASH =
        keccak256(
            "Craft(address signer,address to,bytes32 burnHash,bytes32 mintHash,uint64 identificationID,uint64 deadline,uint256 nonce)"
        );

    address private m_Owner;
    address private m_Signer;

    ITokenRole private immutable m_RoleToken;
    ITokenPart private immutable m_PartToken;
    ITokenPet private immutable m_PetToken;
    ITokenItem private immutable m_ItemToken;

    mapping(address => uint256) private m_Nonces;

    constructor(
        address ownerAddr,
        address signerAddr,
        address antAddr,
        address partAddr,
        address petAddr,
        address itemAddr
    ) EIP712("CraftModuleV1", "1") {
        require(
            ownerAddr != address(0) && signerAddr != address(0),
            "addr err"
        );
        require(antAddr != address(0) && partAddr != address(0), "addr err");
        require(petAddr != address(0) && itemAddr != address(0), "addr err");
        m_Owner = ownerAddr;
        m_Signer = signerAddr;
        m_RoleToken = ITokenRole(antAddr);
        m_PartToken = ITokenPart(partAddr);
        m_PetToken = ITokenPet(petAddr);
        m_ItemToken = ITokenItem(itemAddr);
    }

    modifier onlyOwner() {
        require(msg.sender == m_Owner, "permission denied !");
        _;
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    function craft(
        BurnItem[] calldata burnList,
        MintInfo calldata mintInfo,
        uint64 identificationID,
        uint64 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (uint256 newTokenId) {
        require(block.timestamp <= deadline, "signature expired");
        require(burnList.length > 0, "burn list empty");

        // 验签（独立函数降低栈深度）
        _verify(burnList, mintInfo, identificationID, deadline, v, r, s);

        // burn 材料
        for (uint256 i = 0; i < burnList.length; i++) {
            if (burnList[i].nftType == 1) {
                require(
                    IERC721(burnList[i].tokenContract).ownerOf(
                        burnList[i].tokenId
                    ) == msg.sender,
                    "not owner"
                );
                _burnERC721(burnList[i].tokenContract, burnList[i].tokenId);
            } else {
                _burnERC1155(
                    burnList[i].tokenContract,
                    msg.sender,
                    burnList[i].tokenId,
                    burnList[i].amount
                );
            }
        }

        // mint 结果
        newTokenId = _mintResult(mintInfo);
        emit event_Craft(msg.sender, identificationID, newTokenId);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    function _verify(
        BurnItem[] calldata burnList,
        MintInfo calldata mintInfo,
        uint64 identificationID,
        uint64 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal {
        bytes32 burnHash = _hashBurnList(burnList);
        bytes32 mintHash = _hashMintInfo(mintInfo);
        uint256 nonce = m_Nonces[msg.sender]++;

        bytes32 structHash = keccak256(
            abi.encode(
                _TYPEHASH,
                m_Signer,
                msg.sender,
                burnHash,
                mintHash,
                identificationID,
                deadline,
                nonce
            )
        );
        require(
            ECDSA.recover(_hashTypedDataV4(structHash), v, r, s) == m_Signer,
            "invalid signature"
        );
    }

    function _hashBurnList(
        BurnItem[] calldata burnList
    ) internal view returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](burnList.length);
        for (uint256 i = 0; i < burnList.length; i++) {
            hashes[i] = keccak256(
                abi.encode(
                    _BURN_TYPEHASH,
                    burnList[i].tokenContract,
                    burnList[i].tokenId,
                    burnList[i].amount,
                    burnList[i].nftType
                )
            );
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function _hashMintInfo(
        MintInfo calldata m
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    m.nftType,
                    m.version,
                    m.characteristics,
                    keccak256(m.attributes),
                    m.display,
                    m.partType,
                    m.quality,
                    m.petId,
                    m.itemId,
                    m.itemAmount
                )
            );
    }

    function _mintResult(
        MintInfo calldata mintInfo
    ) internal returns (uint256) {
        if (mintInfo.nftType == 0) {
            return 0; // 合成空：仅销毁材料，不产出新 NFT
        } else if (mintInfo.nftType == 1) {
            return
                m_RoleToken.mint(
                    msg.sender,
                    mintInfo.version,
                    mintInfo.characteristics,
                    mintInfo.attributes
                );
        } else if (mintInfo.nftType == 2) {
            Part memory newPart = Part({
                TokenID: 0,
                TokenOwner: msg.sender,
                Display: mintInfo.display,
                Type: mintInfo.partType,
                Quality: mintInfo.quality,
                Attributes: mintInfo.attributes
            });
            m_PartToken.mint(newPart);
            return 0;
        } else if (mintInfo.nftType == 3) {
            return m_PetToken.mint(msg.sender, mintInfo.petId, mintInfo.attributes);
        } else if (mintInfo.nftType == 4) {
            m_ItemToken.mint(
                msg.sender,
                mintInfo.itemId,
                mintInfo.itemAmount,
                ""
            );
            return mintInfo.itemId;
        }
        revert("unknown nft type");
    }

    function _burnERC721(address tokenContract, uint256 tokenId) internal {
        if (tokenContract == address(m_RoleToken)) m_RoleToken.burn(tokenId);
        else if (tokenContract == address(m_PartToken))
            m_PartToken.burn(tokenId);
        else if (tokenContract == address(m_PetToken)) m_PetToken.burn(tokenId);
        else revert("unknown ERC721 contract");
    }

    function _burnERC1155(
        address tokenContract,
        address account,
        uint256 id,
        uint256 amount
    ) internal {
        if (tokenContract == address(m_ItemToken))
            m_ItemToken.burn(account, id, amount);
        else revert("unknown ERC1155 contract");
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    function setSigner(address addr) external onlyOwner {
        require(addr != address(0));
        m_Signer = addr;
    }
    function setOwner(address addr) external onlyOwner {
        require(addr != address(0));
        m_Owner = addr;
    }
    function nonces(address account) external view returns (uint256) {
        return m_Nonces[account];
    }
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}
