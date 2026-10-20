// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19 <0.9.0;

import "../definition/MutantBloodStruct_Item.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

interface ITokenItem is IERC1155 {
    function getItemData(uint256 id) external view returns (Item memory);

    function mint(
        address to,
        uint256 id,
        uint256 amount,
        bytes memory data
    ) external;

    function mintBatch(
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) external;

    function burn(address account, uint256 id, uint256 value) external;

    function burnBatch(
        address account,
        uint256[] memory ids,
        uint256[] memory values
    ) external;
}
