// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19 <0.9.0;

struct Part {
    uint64 TokenID;
    address TokenOwner;
    uint8 Display;
    uint8 Type;
    uint8 Quality;
    bytes Attributes;
}
