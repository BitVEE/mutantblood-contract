// SPDX-License-Identifier: MIT
pragma solidity >=0.8.9;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "../../interface/ITokenItem.sol";

/////////////////////////////////////////////////////////////////////////////////////////////////////////
// MutantBloodItem：道具 ERC-1155
// 改动：
//   1. 白名单 Operator 机制（只能通过平台合约操作）
//   2. 修复 L-04：pause 检查提前到 super 前
//   3. 构造函数参数化
/////////////////////////////////////////////////////////////////////////////////////////////////////////
contract MutantBloodItem is ERC1155, ERC2981, Pausable, ITokenItem {
    using Strings for uint256;

    event event_ItemBalance(
        uint256 timestamp,
        address indexed account,
        uint256 indexed id,
        uint8 quality,
        uint256 value
    );

    string private m_Name;
    address private m_Owner;

    mapping(address => bool) public m_Minter;
    // 白名单 Operator（MarketContract 用于 ERC-1155 转移）
    mapping(address => bool) public m_AllowedOperator;
    mapping(uint256 => Item) private m_ItemToken;

    constructor(
        address ownerAddr,
        address royaltyReceiver
    ) ERC1155("https://static.mutantblood.net/item/") {
        require(ownerAddr != address(0), "owner addr err");
        require(royaltyReceiver != address(0), "royalty addr err");
        m_Name = "Mutant Blood Item";
        m_Owner = ownerAddr;
        _setDefaultRoyalty(royaltyReceiver, 500);
        // Item types are registered after deployment through setItemToken.
    }

    modifier onlyOwner() {
        require(m_Owner == _msgSender(), "permission denied !");
        _;
    }

    modifier onlyMinter() {
        require(m_Minter[_msgSender()], "permission denied !");
        _;
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    function mint(
        address to,
        uint256 id,
        uint256 amount,
        bytes memory data
    ) external onlyMinter {
        _mint(to, id, amount, data);
    }

    function mintBatch(
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) external onlyMinter {
        _mintBatch(to, ids, amounts, data);
    }

    // ERC-1155 burn：onlyMinter 鉴权，account 必须是调用者或已授权
    function burn(
        address account,
        uint256 id,
        uint256 value
    ) external onlyMinter {
        require(
            account == _msgSender() || isApprovedForAll(account, _msgSender()),
            "caller not approved"
        );
        _burn(account, id, value);
    }

    function burnBatch(
        address account,
        uint256[] memory ids,
        uint256[] memory values
    ) external onlyMinter {
        require(
            account == _msgSender() || isApprovedForAll(account, _msgSender()),
            "caller not approved"
        );
        _burnBatch(account, ids, values);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    function name() external view returns (string memory) {
        return m_Name;
    }

    function getItemData(uint256 id) external view returns (Item memory) {
        return m_ItemToken[id];
    }

    function uri(uint256 id) public view override returns (string memory) {
        require(m_ItemToken[id].ItemID > 0, "invalid token id");
        string memory baseUri = super.uri(0);
        return
            string(abi.encodePacked(baseUri, id.toString(), "/meta_data.json"));
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC1155, ERC2981, IERC165) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    function setURI(string memory newuri) public onlyOwner {
        _setURI(newuri);
    }

    function suspend(bool state) public onlyOwner {
        if (state) {
            _pause();
        } else {
            _unpause();
        }
    }

    function setOwner(address addr) public onlyOwner {
        require(addr != address(0), "owner address err !");
        m_Owner = addr;
    }

    function setMinter(address addr, bool enable) public onlyOwner {
        require(addr != address(0), "minter address err !");
        m_Minter[addr] = enable;
    }

    function setAllowedOperator(address op, bool allow) external onlyOwner {
        require(op != address(0), "operator address err !");
        m_AllowedOperator[op] = allow;
    }

    function isAllowedOperator(address op) external view returns (bool) {
        return m_AllowedOperator[op];
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

    function setItemToken(
        uint256 itemID,
        uint256 itemQuality,
        string calldata tokenName
    ) external onlyOwner {
        _setItemToken(itemID, itemQuality, tokenName);
    }

    // ERC-1155 白名单 Operator：覆盖 setApprovalForAll，限制只能授权给白名单合约
    function setApprovalForAll(
        address operator,
        bool approved
    ) public override(ERC1155, IERC1155) {
        require(
            !approved || m_AllowedOperator[operator],
            "operator not in allowlist"
        );
        super.setApprovalForAll(operator, approved);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    function _setItemToken(
        uint256 itemID,
        uint256 itemQuality,
        string memory tokenName
    ) internal {
        m_ItemToken[itemID] = Item(
            uint32(itemID),
            uint8(itemQuality),
            tokenName
        );
    }

    function _beforeTokenTransfer(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) internal override {
        // 修复 L-04：pause 检查提前，节省 gas
        require(!paused(), "token transfer while paused");

        // 白名单限制：mint(from=0) 和 burn(to=0) 不受限，其余转移必须经白名单 operator
        if (from != address(0) && to != address(0)) {
            require(
                m_AllowedOperator[operator],
                "only allowed operator can transfer"
            );
        }

        for (uint256 i = 0; i < ids.length; i++) {
            require(m_ItemToken[ids[i]].ItemID > 0, "invalid token id");
        }

        super._beforeTokenTransfer(operator, from, to, ids, amounts, data);
    }

    function _afterTokenTransfer(
        address,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory,
        bytes memory
    ) internal override {
        for (uint256 i = 0; i < ids.length; i++) {
            if (from != address(0)) {
                emit event_ItemBalance(
                    block.timestamp,
                    from,
                    ids[i],
                    m_ItemToken[ids[i]].ItemQuality,
                    balanceOf(from, ids[i])
                );
            }
            if (to != address(0)) {
                emit event_ItemBalance(
                    block.timestamp,
                    to,
                    ids[i],
                    m_ItemToken[ids[i]].ItemQuality,
                    balanceOf(to, ids[i])
                );
            }
        }
    }
}
