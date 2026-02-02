# FPGA Chess Game – Verilog Implementation

## Overview

This project presents the design and implementation of a two-player chess game on an FPGA platform, developed using the Verilog hardware description language.  
The system renders a complete chessboard and pieces in real time using a VGA interface (640×480 @ 60 Hz) and enables user interaction through on-board buttons.

The primary goal of the project was to demonstrate practical digital system design concepts, including synchronous logic design, VGA signal generation, state management, and hardware-level user interaction on a Xilinx Spartan-3E FPGA.

---

## Key Features and Design Highlights

- **VGA Signal Generation**  
  Implemented a full VGA timing controller compliant with 640×480 @ 60 Hz, including horizontal and vertical synchronization, front/back porch handling, and pixel-level color control.

- **Graphical Chessboard Rendering**  
  The chessboard is rendered within a 400×400 active display area. Each square is drawn dynamically based on pixel coordinates, ensuring correct alignment and color alternation.

- **Piece Representation and Rendering**  
  All chess pieces (pawn, rook, bishop, knight, queen, king) are rendered using per-pixel silhouette logic.  
  Each piece is assigned a unique ID and type, allowing efficient tracking and manipulation directly in hardware.

- **ID-Based Game State Management**  
  The system maintains arrays for piece identity, type, and board position, enabling deterministic and hardware-friendly game state control without the use of external memory.

- **Two-Player Interaction Logic**  
  Turn-based gameplay is implemented with visual highlighting of the active player.  
  Players interact using directional buttons to navigate the board and a central button to pick up or place pieces.

- **Move Execution and Capture Handling**  
  The design supports basic chess move execution, including piece relocation and capture logic, handled entirely within synchronous Verilog logic.

- **Visual Move Timer**  
  A hardware-driven visual timer is implemented using descending colored lines on the display, indicating the remaining time for the current player’s move.

- **Hardware Reset Functionality**  
  A dedicated switch allows the entire game state and timer to be reset instantly, restoring the initial board configuration.

---

## Controls and User Interaction

- **BTN_L** – move cursor left
- **BTN_R** – move cursor right
- **ROT_BT** – move cursor up
- **BTN_SR** – move cursor down

- **TAKE/PLACE button (click → `TAKE_p`)**  
  Select a piece (pick up) or place it on the target square (including captures).

- **SW3** – reset board state and move timer

---

## Technology Stack

- **FPGA Platform**  
  Xilinx Spartan-3E

- **Hardware Description Language**  
  Verilog HDL

- **Graphics Output**  
  VGA (RGB + HSYNC / VSYNC)

- **Constraints**  
  UCF (User Constraints File) for pin mapping and I/O configuration

- **Clocking**  
  On-board FPGA system clock



