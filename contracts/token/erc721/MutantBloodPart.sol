// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19 <0.9.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";
import "../../library/BinaryAttribute.sol";
import "../../interface/ITokenPart.sol";

/////////////////////////////////////////////////////////////////////////////////////////////////////////
// MutantBloodPart：零件 NFT
// 改动：
//   1. 白名单 Operator 机制（只能通过平台合约转移）
//   2. 修复 burn 双重鉴权矛盾（M-02）
//   3. getPartData 加存在性检查（L-03）
//   4. 构造函数参数化
/////////////////////////////////////////////////////////////////////////////////////////////////////////
contract MutantBloodPart is ERC721, ERC721Enumerable, ERC2981, ITokenPart {
    using Strings for uint256;

    event event_CreatePart(
        address indexed ownerAddr,
        uint256 indexed tokenID,
        Part partData
    );
    event event_DestroyPart(address indexed ownerAddr, uint256 indexed tokenID);
    event event_TransferPart(
        address indexed ownerAddr,
        uint256 indexed tokenID,
        address indexed toAddr
    );

    uint256 private m_PartTokenID = 1000;
    string private m_PartBaseURI = "https://static.mutantblood.net/part/";

    address private m_Owner;
    mapping(address => uint256) public m_GameAdmin;
    mapping(address => bool) public m_AllowedOperator;
    mapping(uint256 => Part) private m_PartList;

    constructor(
        address ownerAddr,
        address royaltyReceiver
    ) ERC721("Mutant Blood Part", "CAP") {
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
    function getPartData(uint256 tokenID) external view returns (Part memory) {
        require(_exists(tokenID), "token not exist");
        return m_PartList[tokenID];
    }

    function getPartDataByIndex(
        address ownerAddr,
        uint256 tokenIndex
    ) external view override returns (Part memory) {
        uint256 tokenID = tokenOfOwnerByIndex(ownerAddr, tokenIndex);
        require(_exists(tokenID), "token not exist");
        return m_PartList[tokenID];
    }

    function getPartAttribute(
        uint256 tokenID
    ) external view returns (Attribute[] memory) {
        require(_exists(tokenID), "token not exist");
        return
            BinaryAttribute.deserializeAttributes(
                m_PartList[tokenID].Attributes
            );
    }

    function getPartAttributeValue(
        uint256 tokenID,
        uint256 attrID
    ) external view returns (uint256) {
        require(_exists(tokenID), "token not exist");
        return
            BinaryAttribute.getAttributeValue(
                m_PartList[tokenID].Attributes,
                attrID
            );
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    function mint(Part memory newPart) external onlyAdmin returns (uint256) {
        uint256 token_id = (++m_PartTokenID);
        _safeMint(newPart.TokenOwner, token_id);
        newPart.TokenID = uint64(token_id);
        m_PartList[token_id] = newPart;
        emit event_CreatePart(newPart.TokenOwner, token_id, newPart);
        return token_id;
    }

    // 修复 M-02：onlyAdmin 单独鉴权，移除 _isApprovedOrOwner
    function burn(uint256 tokenID) external onlyAdmin {
        require(_exists(tokenID), "token not exist");
        address owner = ownerOf(tokenID);
        emit event_DestroyPart(owner, tokenID);
        _burn(tokenID);
        delete m_PartList[tokenID];
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
        m_PartBaseURI = baseURI;
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
        return (super._exists(tokenID) && m_PartList[tokenID].TokenID != 0);
    }

    function _transfer(
        address from,
        address to,
        uint256 tokenID
    ) internal override {
        super._transfer(from, to, tokenID);
        if (m_PartList[tokenID].TokenID != 0) {
            m_PartList[tokenID].TokenOwner = to;
        }
        emit event_TransferPart(from, tokenID, to);
    }

    function tokenURI(
        uint256 tokenID
    ) public view override returns (string memory) {
        require(_exists(tokenID), "invalid token id");
        return
            string(
                abi.encodePacked(
                    m_PartBaseURI,
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
