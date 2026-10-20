// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19 <0.9.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";
import "../../interface/ITokenPet.sol";

/////////////////////////////////////////////////////////////////////////////////////////////////////////
// MutantBloodPet：宠物 NFT
// 改动：
//   1. 白名单 Operator 机制
//   2. 修复 burn 双重鉴权矛盾
//   3. 构造函数参数化
//   4. 简化数据模型：使用 bytes attributes 替代固定技能数组
/////////////////////////////////////////////////////////////////////////////////////////////////////////
contract MutantBloodPet is ERC721, ERC721Enumerable, ERC2981, ITokenPet {
    using Strings for uint256;

    event event_CreatePet(
        address indexed ownerAddr,
        uint64 timestamp,
        uint256 indexed tokenID,
        uint32 petID,
        bytes attributes
    );
    event event_DestroyPet(
        address indexed ownerAddr,
        uint64 timestamp,
        uint256 indexed tokenID
    );
    event event_TransferPet(
        address indexed ownerAddr,
        uint64 timestamp,
        uint256 indexed tokenID,
        address indexed toAddr
    );
    event event_UpdatePet(
        address indexed ownerAddr,
        uint64 timestamp,
        uint256 indexed tokenID,
        bytes attributes
    );

    uint256 private m_PetTokenID = 1000;
    string private m_PetBaseURI = "https://static.mutantblood.net/pet/";

    address private m_Owner;
    mapping(address => uint256) public m_GameAdmin;
    mapping(address => bool) public m_AllowedOperator;
    mapping(uint256 => Pet) private m_PetList;

    constructor(
        address ownerAddr,
        address royaltyReceiver
    ) ERC721("Mutant Blood Pet", "PET") {
        require(ownerAddr != address(0), "owner addr err");
        require(royaltyReceiver != address(0), "royalty addr err");
        m_Owner = ownerAddr;
        _setDefaultRoyalty(royaltyReceiver, 500);
    }

    modifier onlyOwner() {
        require(m_Owner == _msgSender(), "permission denied !");
        _;
    }

    modifier onlyAdmin() {
        require(m_GameAdmin[_msgSender()] > 0, "permission denied !");
        _;
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    function getPetData(uint256 tokenID) external view returns (Pet memory) {
        return m_PetList[tokenID];
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    function mint(
        address ownerAddr,
        uint256 petID,
        bytes calldata attributes
    ) external onlyAdmin returns (uint256) {
        uint256 token_id = (++m_PetTokenID);
        _safeMint(ownerAddr, token_id);

        Pet storage newPet = m_PetList[token_id];
        newPet.TokenID = uint64(token_id);
        newPet.TokenOwner = ownerAddr;
        newPet.PetID = uint32(petID);
        newPet.Attributes = attributes;

        emit event_CreatePet(
            ownerAddr,
            uint64(block.timestamp),
            token_id,
            uint32(petID),
            attributes
        );
        return token_id;
    }

    // 修复 M-02：onlyAdmin 单独鉴权，移除 _isApprovedOrOwner
    function burn(uint256 tokenID) external onlyAdmin {
        require(_exists(tokenID), "token not exist");
        address owner = ownerOf(tokenID);
        emit event_DestroyPet(owner, uint64(block.timestamp), tokenID);
        _burn(tokenID);
        delete m_PetList[tokenID];
    }

    function setPetAttributes(
        uint256 tokenID,
        bytes calldata attributes
    ) external onlyAdmin {
        require(_exists(tokenID), "token not exist");

        Pet storage petData = m_PetList[tokenID];
        petData.Attributes = attributes;

        emit event_UpdatePet(
            petData.TokenOwner,
            uint64(block.timestamp),
            tokenID,
            attributes
        );
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    function setOwner(address newAddr) external onlyOwner {
        require(newAddr != address(0), "owner address err !");
        m_Owner = newAddr;
    }

    function setGameAdmin(
        address adminAddr,
        uint256 actived
    ) external onlyOwner {
        require(adminAddr != address(0), "admin address err !");
        m_GameAdmin[adminAddr] = actived;
    }

    function setAllowedOperator(address op, bool allow) external onlyOwner {
        require(op != address(0), "operator address err !");
        m_AllowedOperator[op] = allow;
    }

    function isAllowedOperator(address op) external view returns (bool) {
        return m_AllowedOperator[op];
    }

    function setBaseTokenURI(string calldata baseURI) external onlyOwner {
        m_PetBaseURI = baseURI;
    }

    function setRoyalty(
        address receiver,
        uint96 feeNumerator
    ) external onlyOwner {
        if (receiver != address(0)) {
            _setDefaultRoyalty(receiver, feeNumerator);
        } else {
            _deleteDefaultRoyalty();
        }
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 firstTokenId,
        uint256 batchSize
    ) internal override(ERC721, ERC721Enumerable) {
        if (from != address(0) && to != address(0)) {
            require(
                m_AllowedOperator[msg.sender],
                "only allowed operator can transfer"
            );
        }
        super._beforeTokenTransfer(from, to, firstTokenId, batchSize);
    }

    function approve(
        address to,
        uint256 tokenId
    ) public override(ERC721, IERC721) {
        require(
            to == address(0) || m_AllowedOperator[to],
            "operator not in allowlist"
        );
        super.approve(to, tokenId);
    }

    function setApprovalForAll(
        address operator,
        bool approved
    ) public override(ERC721, IERC721) {
        require(
            !approved || m_AllowedOperator[operator],
            "operator not in allowlist"
        );
        super.setApprovalForAll(operator, approved);
    }

    function _exists(uint256 tokenID) internal view override returns (bool) {
        return (super._exists(tokenID) && m_PetList[tokenID].TokenID != 0);
    }

    function _transfer(
        address from,
        address to,
        uint256 tokenID
    ) internal override {
        super._transfer(from, to, tokenID);
        if (m_PetList[tokenID].TokenID != 0) {
            m_PetList[tokenID].TokenOwner = to;
        }
        emit event_TransferPet(from, uint64(block.timestamp), tokenID, to);
    }

    function tokenURI(
        uint256 tokenID
    ) public view override returns (string memory) {
        require(_exists(tokenID), "invalid token id");
        return
            string(
                abi.encodePacked(
                    m_PetBaseURI,
                    tokenID.toString(),
                    "/meta_data.json"
                )
            );
    }

    function supportsInterface(
        bytes4 interfaceId
    )
        public
        view
        override(ERC721, ERC721Enumerable, ERC2981, IERC165)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
