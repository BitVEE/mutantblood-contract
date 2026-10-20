// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19 <0.9.0;

struct Pet {
    uint64 TokenID;
    address TokenOwner;
    uint32 PetID;
    bytes Attributes; // 技能/属性数据，由业务层自由编码
}
