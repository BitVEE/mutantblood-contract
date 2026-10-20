// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19 <0.9.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";
import "../../library/BinaryAttribute.sol";
import "../../interface/ITokenRole.sol";

/////////////////////////////////////////////////////////////////////////////////////////////////////////
// RoleCore：存储 Role 数据
/////////////////////////////////////////////////////////////////////////////////////////////////////////
contract RoleCore {
    address private immutable m_Master;
    mapping(uint256 => Role) private m_RoleList;

    constructor(address masterAddr) {
        m_Master = masterAddr;
    }

    modifier onlyMaster() {
        require(m_Master == msg.sender, "permission denied !");
        _;
    }

    function existRole(uint256 tokenID) public view returns (bool) {
        return m_RoleList[tokenID].TokenID != 0;
    }

    function getRole(uint256 tokenID) public view returns (Role memory) {
        require(existRole(tokenID), "invalid token id");
        return m_RoleList[tokenID];
    }

    function getAttribute(
        uint256 tokenID
    ) public view returns (Attribute[] memory) {
        require(existRole(tokenID), "invalid token id");
        return
            BinaryAttribute.deserializeAttributes(
                m_RoleList[tokenID].Attributes
            );
    }

    function getAttributeValue(
        uint256 tokenID,
        uint256 attrID
    ) public view returns (uint256) {
        require(existRole(tokenID), "invalid token id");
        return
            BinaryAttribute.getAttributeValue(
                m_RoleList[tokenID].Attributes,
                attrID
            );
    }

    function create(Role memory newRole) public onlyMaster {
        require(newRole.Attributes.length > 0, "attribute list err!");
        m_RoleList[newRole.TokenID] = newRole;
    }

    // 修复 M-01：完整清除 struct，确保 existRole() 返回 false
    function destroy(uint256 tokenID) public onlyMaster {
        require(existRole(tokenID), "invalid token id");
        delete m_RoleList[tokenID];
    }

    function transfer(uint256 tokenID, address newAddr) public onlyMaster {
        require(existRole(tokenID), "invalid token id");
        m_RoleList[tokenID].TokenOwner = newAddr;
    }

    function appendAttribute(
        uint256 tokenID,
        uint256 attrID,
        uint256 attrValue
    ) public onlyMaster {
        require(existRole(tokenID), "invalid token id");
        BinaryAttribute.pushAttribute(
            m_RoleList[tokenID].Attributes,
            attrID,
            attrValue
        );
    }

    function changeAttribute(
        uint256 tokenID,
        uint256 attrID,
        uint256 attrValue
    ) public onlyMaster {
        require(existRole(tokenID), "invalid token id");
        BinaryAttribute.setAttribute(
            m_RoleList[tokenID].Attributes,
            attrID,
            attrValue
        );
    }

    function replaceAttributes(
        uint256 tokenID,
        bytes calldata newAttributes
    ) public onlyMaster {
        require(existRole(tokenID), "invalid token id");
        require(newAttributes.length > 0, "attributes empty");
        require(newAttributes.length % 4 == 0, "attributes length err");
        m_RoleList[tokenID].Attributes = newAttributes;
    }
}

/////////////////////////////////////////////////////////////////////////////////////////////////////////
// MutantBloodRole：NFT 主合约
// 改动：
//   1. 白名单 Operator 机制（NFT 只能通过平台市场转移）
//   2. 修复 burn 双重鉴权矛盾（admin 可直接 burn，无需 _isApprovedOrOwner）
//   3. 新增 setAllowedOperator，构造函数去掉硬编码地址
/////////////////////////////////////////////////////////////////////////////////////////////////////////
contract MutantBloodRole is ERC721, ERC721Enumerable, ERC2981, ITokenRole {
    using Strings for uint256;

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    event event_CreateRole(
        address indexed ownerAddr,
        uint256 indexed tokenID,
        Role roleData
    );
    event event_DestroyRole(address indexed ownerAddr, uint256 indexed tokenID);

    event event_TransferRole(
        address indexed ownerAddr,
        uint256 indexed tokenID,
        address indexed toAddr
    );
    event event_AppendRoleAttribute(
        address indexed ownerAddr,
        uint256 indexed tokenID,
        uint256 attrID,
        uint256 attrValue
    );
    event event_ChangeRoleAttribute(
        address indexed ownerAddr,
        uint256 indexed tokenID,
        uint256 attrID,
        uint256 attrValue
    );
    event event_BatchChangeAttributes(
        address indexed ownerAddr,
        uint256 indexed tokenID,
        bytes oldAttributes,
        bytes newAttributes
    );

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    RoleCore private immutable m_RoleCore;

    address private m_Owner;
    mapping(address => uint256) public m_GameAdmin;
    // 白名单 Operator（MarketContract、CraftModule 等）
    mapping(address => bool) public m_AllowedOperator;

    string private m_RoleTokenURI = "https://static.mutantblood.net/role/";
    uint256 private m_RoleTokenID = 1000;

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    constructor(
        address ownerAddr,
        address royaltyReceiver
    ) ERC721("Mutant Blood Role", "ROLE") {
        require(ownerAddr != address(0), "owner addr err");
        require(royaltyReceiver != address(0), "royalty addr err");

        m_RoleCore = new RoleCore(address(this));
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
    function getRoleData(
        uint256 tokenID
    ) external view override returns (Role memory) {
        return m_RoleCore.getRole(tokenID);
    }

    function getRoleDataByIndex(
        address ownerAddr,
        uint256 tokenIndex
    ) external view override returns (Role memory) {
        uint256 tokenID = tokenOfOwnerByIndex(ownerAddr, tokenIndex);
        return m_RoleCore.getRole(tokenID);
    }

    function getRoleAttribute(
        uint256 tokenID
    ) external view returns (Attribute[] memory) {
        return m_RoleCore.getAttribute(tokenID);
    }

    function getRoleAttributeValue(
        uint256 tokenID,
        uint256 attrID
    ) external view override returns (uint256) {
        return m_RoleCore.getAttributeValue(tokenID, attrID);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // mint：仅 Admin（GameAdmin 或 MintSale 合约）可调用
    function mint(
        address ownerAddr,
        uint32 version,
        uint64 characteristics,
        bytes calldata attributes
    ) external override onlyAdmin returns (uint256) {
        uint256 token_id = (++m_RoleTokenID);
        _safeMint(ownerAddr, token_id);

        Role memory newRole = Role({
            TokenID: uint64(token_id),
            TokenOwner: ownerAddr,
            Version: uint32(version),
            Characteristics: uint64(characteristics),
            Birthday: uint64(block.timestamp),
            Attributes: attributes
        });

        m_RoleCore.create(newRole);
        emit event_CreateRole(ownerAddr, token_id, newRole);
        return token_id;
    }

    // burn：修复 M-02，onlyAdmin 单独鉴权，无需 _isApprovedOrOwner
    // CraftModule 作为 AllowedOperator + Admin，通过玩家 approve 后调用
    function burn(uint256 tokenID) external onlyAdmin {
        require(_exists(tokenID), "token not exist");
        address owner = ownerOf(tokenID);
        emit event_DestroyRole(owner, tokenID);
        _burn(tokenID);
        m_RoleCore.destroy(tokenID);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // 属性管理：Admin 直接调用，移除 ownerAddr 鉴权（onlyAdmin 即足够）
    function appendRoleAttribute(
        address ownerAddr,
        uint256 tokenID,
        uint256 attrID,
        uint256 attrValue
    ) external override onlyAdmin {
        require(_exists(tokenID), "token not exist");
        m_RoleCore.appendAttribute(tokenID, attrID, attrValue);
        emit event_AppendRoleAttribute(ownerAddr, tokenID, attrID, attrValue);
    }

    function changeRoleAttribute(
        address ownerAddr,
        uint256 tokenID,
        uint256 attrID,
        uint256 attrValue
    ) external override onlyAdmin {
        require(_exists(tokenID), "token not exist");
        m_RoleCore.changeAttribute(tokenID, attrID, attrValue);
        emit event_ChangeRoleAttribute(ownerAddr, tokenID, attrID, attrValue);
    }

    function batchChangeAttributes(
        address ownerAddr,
        uint256 tokenID,
        bytes calldata newAttributes
    ) external override onlyAdmin {
        require(_exists(tokenID), "token not exist");
        bytes memory oldAttributes = m_RoleCore.getRole(tokenID).Attributes;
        m_RoleCore.replaceAttributes(tokenID, newAttributes);
        emit event_BatchChangeAttributes(
            ownerAddr,
            tokenID,
            oldAttributes,
            newAttributes
        );
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // 管理函数
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

    // 白名单 Operator 管理（MarketContract、CraftModule 地址部署后设置）
    function setAllowedOperator(address op, bool allow) external onlyOwner {
        require(op != address(0), "operator address err !");
        m_AllowedOperator[op] = allow;
    }

    function isAllowedOperator(address op) external view returns (bool) {
        return m_AllowedOperator[op];
    }

    function setBaseTokenURI(string calldata baseTokenURI) external onlyOwner {
        m_RoleTokenURI = baseTokenURI;
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
    // 内部函数：白名单转移限制（mint/burn 除外）
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 firstTokenId,
        uint256 batchSize
    ) internal override(ERC721, ERC721Enumerable) {
        // mint(from=0) 和 burn(to=0) 不受限制，只限制普通转移
        if (from != address(0) && to != address(0)) {
            require(
                m_AllowedOperator[msg.sender],
                "only allowed operator can transfer"
            );
        }
        super._beforeTokenTransfer(from, to, firstTokenId, batchSize);
    }

    // 锁定 approve：只有白名单内的 operator 才能被 approve
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

    // 锁定 setApprovalForAll：只有白名单内的 operator 才能被批量授权
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
        return (super._exists(tokenID) && m_RoleCore.existRole(tokenID));
    }

    function _transfer(
        address from,
        address to,
        uint256 tokenID
    ) internal override {
        super._transfer(from, to, tokenID);
        m_RoleCore.transfer(tokenID, to);
        emit event_TransferRole(from, tokenID, to);
    }

    function tokenURI(
        uint256 tokenID
    ) public view override returns (string memory) {
        require(_exists(tokenID), "invalid token id");
        return
            string(
                abi.encodePacked(
                    m_RoleTokenURI,
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
