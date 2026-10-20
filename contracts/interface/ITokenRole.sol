// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19 <0.9.0;

import "../definition/MutantBloodStruct_Role.sol";
import "../definition/MutantBloodStruct_Attribute.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface ITokenRole is IERC721 {
    function getRoleData(uint256 tokenID) external view returns (Role memory);

    function getRoleDataByIndex(
        address ownerAddr,
        uint256 tokenIndex
    ) external view returns (Role memory);

    function getRoleAttribute(
        uint256 tokenID
    ) external view returns (Attribute[] memory);

    function getRoleAttributeValue(
        uint256 tokenID,
        uint256 attrID
    ) external view returns (uint256);

    function mint(
        address ownerAddr,
        uint32 version,
        uint64 characteristics,
        bytes calldata attributes
    ) external returns (uint256);

    function burn(uint256 tokenID) external;

    function appendRoleAttribute(
        address ownerAddr,
        uint256 tokenID,
        uint256 attrID,
        uint256 attrValue
    ) external;

    function changeRoleAttribute(
        address ownerAddr,
        uint256 tokenID,
        uint256 attrID,
        uint256 attrValue
    ) external;

    function batchChangeAttributes(
        address ownerAddr,
        uint256 tokenID,
        bytes calldata newAttributes
    ) external;
}
