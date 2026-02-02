`timescale 1ns / 1ps
module sah(
  input  CLK, BTN_R, BTN_RST, BTN_L, BTN_SR, ROT_BT, reset, SW3,
  output VGA_H, VGA_V, VGA_R, VGA_G, VGA_B
);

  // brojaci piksela , tempo
  reg [9:0] h_counter = 0, v_counter = 0;
  reg [9:0] vcount_next = 0, hcount_next = 0;
  reg hsync_next, vsync_next, hsync, vsync;
  reg clk25 = 0;
  reg zelena = 0, plava = 0, crvena = 0;
  
  // parametri za ekran 640x480@60
  localparam h_display    = 640;
  localparam h_frontporch = 16;
  localparam h_syncwidth  = 96;
  localparam h_backporch  = 48;
  localparam h_total      = 800;
  localparam v_display    = 480;
  localparam v_frontporch = 10;
  localparam v_syncwidth  = 2;
  localparam v_backporch  = 33;
  localparam v_total      = 525;

  reg click_s0 = 0, click_s1 = 0, click_prev = 0; // Dva flip-flopa (click_s0 › click_s1) "smire" tipku u clk25 domeni
  reg btnL_q=0, btnR_q=0, btnU_q=0, btnD_q=0; //  Stanje tipaka za kretanje
  reg [2:0] pokazivac_x = 0, pokazivac_y = 0; //  Highlighter (pokazivač po ploči 8x8)
  reg [5:0] tmp_id; // Privremeni id figure
  reg turn_white = 1'b1; // Tko je na potezu: 1 = bijeli (žuti highlighter), 0 = crni (crveni highlighter)

  reg holding = 1'b0;
  reg [5:0]  sel_id  = 6'h3F;   // Figura koju smo uzeli
   // ID figura , pozicija
  reg [6:0] pos  [0:31];                 
  localparam [6:0] NONE = 7'h7F;         
  reg [3:0] kind [0:31];     
  // Usporavanje kretanja pokazivaca (~100ms @ 25MHz) 
  reg [21:0] slow_cnt = 0;
  wire tick = (slow_cnt == 22'd2_499_999);
 
  //  VIZUALNI "TAJMER" LINIJE 
  localparam integer LINE_LEFT_X1  = 60;   // žuta linija (bijeli) - lijevo od ploče
  localparam integer LINE_LEFT_X2  = 100;
  localparam integer LINE_RIGHT_X1 = 540;  // crvena linija (crni) - desno od ploče
  localparam integer LINE_RIGHT_X2 = 580;
  localparam integer BOOST_PIXELS = 67;

  reg [8:0]  line_y_white = 0;  // 0..399 relativno na Y0
  reg [8:0]  line_y_black = 0;
  reg        run_white_line = 1'b0;
  reg        run_black_line = 1'b0;
  reg        first_line_started = 1'b0;  // samo da žuta ne krene dok prvi put ne uzme bijeli
  reg        turn_white_q = 1'b1;        // za detekciju ruba smjene
// --- GAME OVER latch ---
reg game_over = 1'b0;

  // brzina spuštanja (?10 ms po pikselu @ 25 MHz › 100 px/s)
  localparam integer LINE_TICKS = 1_875_000;
  reg [31:0] line_div = 0;
  wire line_tick = (line_div == LINE_TICKS-1);


 // logika za Highlighter
  wire [9:0] kocka_x1 = 120 + pokazivac_x * 50;
  wire [9:0] kocka_x2 = kocka_x1 + 49;
  wire [9:0] kocka_y1 =  40 + pokazivac_y * 50;
  wire [9:0] kocka_y2 = kocka_y1 + 49;

  wire [5:0] cur_idx = pokazivac_y * 6'd8 + pokazivac_x; // Indeks polja (0..63)

  localparam ACTIVE_LOW_CLICK = 1'b1;          //  Ako je tipka aktivna na 0, stavi ACTIVE_LOW_CLICK=1,
  wire click_raw = (ACTIVE_LOW_CLICK) ? ~BTN_RST : BTN_RST; // 'click_raw' samo okrene nivo tako da PRITISNUTO bude logička 1.
 

  //  Ploča: iz piksela -> tile_x/tile_y/tile_idx BEZ / i % 
  localparam X0 = 120, Y0 = 40;
  wire inside_board = (h_counter >= X0 && h_counter < X0 + 10'd400 &&
                       v_counter >= Y0 && v_counter < Y0 + 10'd400);
  wire [9:0] lx = h_counter - X0;   // 0..399
  wire [9:0] ly = v_counter - Y0;   // 0..399
  
 //  debounce i cooldown samo za CLICK (ROT_BT) 
localparam integer DEB_TICKS  = 250_000;    // ~10 ms @ 25 MHz
localparam integer RATE_TICKS = 3_000_000;  // ~120 ms @ 25 MHz

reg        click_m = 0, click_s = 0;        // 2x sync u clk25
reg        click_state = 0, click_prev_db = 0;
reg [18:0] dbC_cnt = 0;                     // brojač za debounce (~10 ms)
reg [21:0] click_cooldown = 0;              // rate-limit (~120 ms)

reg  take_pulse = 1'b0;   // 1-taktan impuls nakon čistog klika
wire TAKE_p     = take_pulse; // zadržavamo isto ime kakvo već koristite

  // Mapa pixel-polje za šahovsku ploču
  function [2:0] seg50(input [9:0] val);
    begin
      if      (val < 10'd50)   seg50 = 3'd0;
      else if (val < 10'd100)  seg50 = 3'd1;
      else if (val < 10'd150)  seg50 = 3'd2;
      else if (val < 10'd200)  seg50 = 3'd3;
      else if (val < 10'd250)  seg50 = 3'd4;
      else if (val < 10'd300)  seg50 = 3'd5;
      else if (val < 10'd350)  seg50 = 3'd6;
      else                     seg50 = 3'd7;
    end
  endfunction

  wire [2:0] tile_x   = seg50(lx);
  wire [2:0] tile_y   = seg50(ly);
  wire [5:0] tile_idx = {tile_y,3'b000} + tile_x;   // y*8 + x

  // lokalne koordinate unutar polja (0..49) bez %
  wire [9:0] mul50x = {tile_x,5'b0} + {tile_x,4'b0} + {tile_x,1'b0}; // 32+16+2
  wire [9:0] mul50y = {tile_y,5'b0} + {tile_y,4'b0} + {tile_y,1'b0};
  wire [9:0] local_x = lx - mul50x; // 0..49
  wire [9:0] local_y = ly - mul50y; // 0..49
  
  // treba za vracanje linija tajmera na pocetno stanje
  reg sw3_m=0, sw3_s=0, sw3_prev=0;
always @(posedge clk25) begin
  sw3_m   <= SW3;
  sw3_s   <= sw3_m;
  sw3_prev<= sw3_s;
end
wire sw3_pulse = sw3_s & ~sw3_prev;  // UZLAZNI rub SW3 u clk25 domeni


  // Crtanje figura
  function pawn_pixel;   input [9:0] x,y; begin
    pawn_pixel = 1'b0;
    if (y>=10 && y<=12 && x>=20 && x<=30) pawn_pixel = 1'b1;
    else if (y>=13 && y<=18 && x>=22 && x<=28) pawn_pixel = 1'b1;
    else if (y>=19 && y<=20 && x>=23 && x<=27) pawn_pixel = 1'b1;
    else if (y>=21 && y<=24 && x>=20 && x<=30) pawn_pixel = 1'b1;
    else if (y>=25 && y<=28 && x>=18 && x<=32) pawn_pixel = 1'b1;
    else if (y>=29 && y<=32 && x>=17 && x<=33) pawn_pixel = 1'b1;
    else if (y>=33 && y<=36 && x>=16 && x<=34) pawn_pixel = 1'b1;
    else if (y>=37 && y<=40 && x>=14 && x<=36) pawn_pixel = 1'b1;
    else if (y>=41 && y<=43 && x>=12 && x<=38) pawn_pixel = 1'b1;
    else if (y>=44 && y<=45 && x>=10 && x<=40) pawn_pixel = 1'b1;
  end endfunction

  function rook_pixel;    input [9:0] x,y; begin
    rook_pixel = 1'b0;
    if (y>=10 && y<=12 && ((x>=12 && x<=16)||(x>=20 && x<=30)||(x>=34 && x<=38))) rook_pixel = 1'b1;
    else if (y>=13 && y<=32 && x>=14 && x<=36) rook_pixel = 1'b1;
    else if (y>=18 && y<=20 && x>=22 && x<=28) rook_pixel = 1'b0;
    else if (y>=33 && y<=36 && x>=12 && x<=38) rook_pixel = 1'b1;
    else if (y>=37 && y<=45 && x>=10 && x<=40) rook_pixel = 1'b1;
  end endfunction

  function bishop_pixel;  input [9:0] x,y; begin
    bishop_pixel = 1'b0;
    if (y>=10 && y<=12 && x>=22 && x<=28) bishop_pixel = 1'b1;
    else if (y>=13 && y<=16 && x>=20 && x<=30) bishop_pixel = 1'b1;
    else if (y>=17 && y<=20 && x>=18 && x<=32) bishop_pixel = 1'b1;
    else if ((x>=y && x<=y+2) && y>=18 && y<=28) bishop_pixel = 1'b1;
    else if (y>=21 && y<=30 && x>=16 && x<=34) bishop_pixel = 1'b1;
    else if (y>=31 && y<=34 && x>=14 && x<=36) bishop_pixel = 1'b1;
    else if (y>=35 && y<=45 && x>=10 && x<=40) bishop_pixel = 1'b1;
  end endfunction

  function knight_pixel;  input [9:0] x,y; begin
    knight_pixel = 1'b0;
    if (y>=12 && y<=16 && x>=24 && x<=32) knight_pixel = 1'b1;
    else if (y>=16 && y<=20 && x>=20 && x<=30) knight_pixel = 1'b1;
    else if (y>=20 && y<=24 && x>=18 && x<=28) knight_pixel = 1'b1;
    else if (y>=24 && y<=28 && x>=16 && x<=26) knight_pixel = 1'b1;
    else if (y>=28 && y<=34 && x>=14 && x<=30) knight_pixel = 1'b1;
    else if (y>=35 && y<=45 && x>=10 && x<=40) knight_pixel = 1'b1;
    if (y>=17 && y<=18 && x>=27 && x<=28) knight_pixel = 1'b0;
  end endfunction

  function queen_pixel;   input [9:0] x,y; begin
    queen_pixel = 1'b0;
    if (y>=10 && y<=12 && ((x>=12 && x<=14)||(x>=20 && x<=22)||(x>=28 && x<=30)||(x>=36 && x<=38))) queen_pixel = 1'b1;
    else if (y>=13 && y<=15 && x>=14 && x<=36) queen_pixel = 1'b1;
    else if (y>=16 && y<=24 && x>=16 && x<=34) queen_pixel = 1'b1;
    else if (y>=25 && y<=28 && x>=18 && x<=32) queen_pixel = 1'b1;
    else if (y>=29 && y<=32 && x>=16 && x<=34) queen_pixel = 1'b1;
    else if (y>=33 && y<=36 && x>=14 && x<=36) queen_pixel = 1'b1;
    else if (y>=37 && y<=45 && x>=10 && x<=40) queen_pixel = 1'b1;
  end endfunction

 function king_pixel;  input [9:0] x,y; begin
  king_pixel = 1'b0;
  if (y >= 4  && y <= 12 && x >= 24 && x <= 26) king_pixel = 1'b1;
  if (y >= 7  && y <= 9  && x >= 20 && x <= 30) king_pixel = 1'b1;
  if (y>=10 && y<=12 && x>=24 && x<=26) king_pixel = 1'b1;
  if (y>=12 && y<=14 && x>=22 && x<=28) king_pixel = 1'b1;
  if (y>=15 && y<=18 && x>=20 && x<=30) king_pixel = 1'b1;
  if (y>=19 && y<=30 && x>=18 && x<=32) king_pixel = 1'b1;
  if (y>=31 && y<=34 && x>=16 && x<=34) king_pixel = 1'b1;
  if (y>=35 && y<=45 && x>=10 && x<=40) king_pixel = 1'b1;
end endfunction

  // Postavljanje indentiteta figurama
  function piece_on; input [3:0] code; input [9:0] x,y; begin
    case (code)
      4'd1, 4'd7:  piece_on = king_pixel(x,y);
      4'd2, 4'd8:  piece_on = queen_pixel(x,y);
      4'd3, 4'd9:  piece_on = rook_pixel(x,y);
      4'd4, 4'd10: piece_on = bishop_pixel(x,y);
      4'd5, 4'd11: piece_on = knight_pixel(x,y);
      4'd6, 4'd12: piece_on = pawn_pixel(x,y);
      default:     piece_on = 1'b0;
    endcase
  end endfunction

 task reset_board_ids;
  integer p;
  begin
    // BIJELI DOLJE 
    pos[0]  <= 56; kind[0]  <= 4'd3;   // rook
    pos[1]  <= 57; kind[1]  <= 4'd5;   // knight
    pos[2]  <= 58; kind[2]  <= 4'd4;   // bishop
    pos[3]  <= 59; kind[3]  <= 4'd2;   // queen
    pos[4]  <= 60; kind[4]  <= 4'd1;   // king
    pos[5]  <= 61; kind[5]  <= 4'd4;   // bishop
    pos[6]  <= 62; kind[6]  <= 4'd5;   // knight
    pos[7]  <= 63; kind[7]  <= 4'd3;   // rook
    // bijeli pijuni (ID 8..15)
    for (p=0; p<8; p=p+1) begin
      pos[8+p]  <= 6'd48 + p[5:0];    
      kind[8+p] <= 4'd6;               
    end
    // plavi pijuni (ID 16..23)
    for (p=0; p<8; p=p+1) begin
      pos[16+p]  <= 6'd8 + p[5:0];    
      kind[16+p] <= 4'd12;          
    end
    //PLAVI GORNJI
    pos[24] <=  0; kind[24] <= 4'd9;   // rook
    pos[25] <=  1; kind[25] <= 4'd11;  // knight
    pos[26] <=  2; kind[26] <= 4'd10;  // bishop
    pos[27] <=  3; kind[27] <= 4'd8;   // queen
    pos[28] <=  4; kind[28] <= 4'd7;   // king
    pos[29] <=  5; kind[29] <= 4'd10;  // bishop
    pos[30] <=  6; kind[30] <= 4'd11;  // knight
    pos[31] <=  7; kind[31] <= 4'd9;   // rook
  end
endtask

  initial begin
    reset_board_ids();
  end

  // Pronalaz figure na odredenom polju
  function [5:0] find_piece_at_idx;
  input [5:0] idx;
  integer i;
  begin
    find_piece_at_idx = 6'h3F;   
    for (i=0; i<32; i=i+1)
      if (pos[i] != NONE && pos[i][6:0] == idx) begin
        find_piece_at_idx = i[5:0];
      end
  end
endfunction


// Debounce + cooldown samo za klik (ROT_BT)
always @(posedge clk25) begin
  // 1) Dvostruki sync u clk25
  click_m <= click_raw;
  click_s <= click_m;

  // 2) Debounce: traži ~10 ms stabilnog stanja prije promjene
  if (click_s == click_state) begin
    dbC_cnt <= 0;         // stabilno, brojač miruje
  end else begin
    if (dbC_cnt == DEB_TICKS-1) begin
      click_state <= click_s;  // potvrdi promjenu stanja
      dbC_cnt     <= 0;
    end else begin
      dbC_cnt <= dbC_cnt + 1;
    end
  end

  // 3) Zadano: nema impulsa u ovom taktu
  take_pulse <= 1'b0;

  // 4) Rate-limit odbrojavanje
  if (reset) begin
    click_cooldown <= 0;
    click_prev_db  <= 0;
  end else begin
    if (click_cooldown != 0) click_cooldown <= click_cooldown - 1;

    // 5) Generiraj 1-taktan impuls samo na UZLAZNOM rubu debounced signala
    //    i samo ako je istekla "hlađenja" (cooldown)
    if ( (click_state & ~click_prev_db) && (click_cooldown == 0) ) begin
      take_pulse     <= 1'b1;           // ovo je vaš novi TAKE_p
      click_cooldown <= RATE_TICKS;     // startaj cooldown (~120 ms)
    end

    click_prev_db <= click_state;
  end
end

// --- Divider za "korak" linije ---
always @(posedge clk25 or posedge reset) begin
  if (reset) line_div <= 0;
  else       line_div <= line_tick ? 0 : line_div + 1;
end

// --- Kretanje linija (spušta se aktivna; resetira se na promjenu poteza) ---
always @(posedge clk25 or posedge reset) begin
  if (reset) begin
    line_y_white       <= 0;
    line_y_black       <= 0;
    run_white_line     <= 1'b0;
    run_black_line     <= 1'b0;
    first_line_started <= 1'b0;
    turn_white_q       <= 1'b1;
	 game_over 			  <= 1'b0;	
  end else begin
  
  if (sw3_pulse) begin
  line_y_white <= 9'd0;
  line_y_black <= 9'd0;
  run_white_line <=1'b0;
  run_black_line <=1'b0;
  first_line_started <= 1'b0;
  turn_white_q <= 1'b1; // prvi iduci potez bijeli
  game_over 	<= 1'b0;
  end

  
  // 1) detekcija promjene smjene (rub turn_white)
  if (!game_over) begin
if (turn_white != turn_white_q) begin
  // upravo je odigrao onaj koji je bio na potezu (turn_white_q)
  if (turn_white_q) begin
    // bijeli je odigrao: umjesto full reseta, digni žutu liniju za +5 s (saturiraj na 0)
    if (line_y_white > BOOST_PIXELS) line_y_white <= line_y_white - BOOST_PIXELS;
    else                             line_y_white <= 9'd0;

    run_white_line <= 1'b0;   // bijeli staje
    run_black_line <= 1'b1;   // crni kreće
  end else begin
    // crni je odigrao: digni crvenu liniju za +5 s (saturiraj na 0)
    if (line_y_black > BOOST_PIXELS) line_y_black <= line_y_black - BOOST_PIXELS;
    else                             line_y_black <= 9'd0;

    run_black_line <= 1'b0;   // crni staje
    run_white_line <= 1'b1;   // bijeli kreće
  end
  turn_white_q <= turn_white;
end
end


    // 2) prvi start: žuta krene tek kad bijeli PRVI put uzme figuru
    if (!first_line_started && TAKE_p && turn_white && !holding) begin
      run_white_line     <= 1'b1;
      first_line_started <= 1'b1; // (dvije linije su ok; efekt je "postavi na 1")
    end

    // 3) pomak po ticku (clamp do dna ploče)
    if (line_tick) begin
      if (run_white_line && line_y_white < 9'd399) line_y_white <= line_y_white + 1;
      if (run_black_line && line_y_black < 9'd399) line_y_black <= line_y_black + 1;
    end
	 // 4) 
	 if ( (run_white_line && (line_y_white >= 9'd399)) ||
			(run_black_line && (line_y_black >= 9'd399)) ) begin
			run_white_line <= 1'b0;
			run_black_line <= 1'b0;
			game_over 		<= 1'b1;
  end
end
end

  
  
  // Logika samog pokazivaca , uzimanje ostavljanje figure te reset 
	always @(posedge clk25) begin
    // usporavanje highlightera
    if (slow_cnt == 22'd2_499_999) slow_cnt <= 0;
    else                           slow_cnt <= slow_cnt + 1;

   

    if (reset) begin
      pokazivac_x <= 0; pokazivac_y <= 0;
      btnL_q <= 0; btnR_q <= 0; btnU_q <= 0; btnD_q <= 0;
      holding <= 1'b0; sel_id <= 6'h3F;
      reset_board_ids();
		turn_white <= 1'b1;
    end else begin
      // kretanje pokazivaca na klik
      if (!game_over && tick) begin
        if (BTN_L && (!btnL_q || BTN_L) && pokazivac_x > 0) pokazivac_x <= pokazivac_x - 1;
        else if (BTN_R && (!btnR_q || BTN_R) && pokazivac_x < 7) pokazivac_x <= pokazivac_x + 1;
        else if (BTN_SR && (!btnD_q || BTN_SR) && pokazivac_y < 7) pokazivac_y <= pokazivac_y + 1; // dolje
        else if (ROT_BT && (!btnU_q || ROT_BT) && pokazivac_y > 0) pokazivac_y <= pokazivac_y - 1; // gore
        btnL_q <= BTN_L; btnR_q <= BTN_R; btnU_q <= ROT_BT; btnD_q <= BTN_SR;
      end
		
		

      // reset ploče
if (SW3) begin
  reset_board_ids();
  holding   <= 1'b0;
  sel_id    <= 6'h3F;
  turn_white <= 1'b1;

  
end


//PICK & PLACE po smjenama (bijeli - crni) 
// Pravila:
// - kad je turn_white=1, smiješ uzeti/dirati SAMO bijelu figuru (kind<=6)
// - kad je turn_white=0, smiješ uzeti/dirati SAMO crnu/plavu figuru (kind>=7)
// - spuštanje: prazno polje OK; suparnik OK (capture); vlastita boja NIJE OK (ostaješ u "holding")
if (!game_over && TAKE_p) begin
  if (!holding) begin
    // pokušaj UZETI figuru na trenutnom polju
    tmp_id = find_piece_at_idx(cur_idx);
    if (tmp_id != 6'h3F) begin
      // provjeri boju figure i smjenu
      if ( (turn_white && (kind[tmp_id] <= 4'd6)) ||
           (!turn_white && (kind[tmp_id] >= 4'd7)) ) begin
        // smiješ uzeti
        sel_id  <= tmp_id;
        holding <= 1'b1;
        pos[tmp_id] <= NONE;           // makni s ploče dok je "u ruci"
      end
      // inače: nije tvoja boja › ignoriraj klik
    end
    // ako je prazno polje › ignoriraj klik
  end else begin
    // držimo figuru: pokušaj SPUSTITI
    tmp_id = find_piece_at_idx(cur_idx);  // tko stoji na ciljnom polju?

    if (tmp_id == 6'h3F) begin
      // prazno polje › spusti
      pos[sel_id] <= {1'b0, cur_idx};
      holding     <= 1'b0;
      sel_id      <= 6'h3F;
      turn_white  <= ~turn_white;        // potez gotov › promijeni smjenu
    end else begin
      // ciljno polje zauzeto
      // provjeri boju figure na ciljnom polju u odnosu na našu (kind[sel_id])
      if ( (kind[sel_id] <= 4'd6) != (kind[tmp_id] <= 4'd6) ) begin
        // suparnik › CAPTURE
        pos[tmp_id]   <= NONE;
        pos[sel_id]   <= {1'b0, cur_idx};
        holding       <= 1'b0;
        sel_id        <= 6'h3F;
        turn_white    <= ~turn_white;    // potez gotov › smjena
      end
      // vlastita boja na ciljnom polju › NIŠTA (ostaješ u holding, traži drugo polje)
    end
  end
end
end
end
  
  // VGA PIXEL PIPE
  
  always @(posedge CLK) begin
  
  clk25 <= ~clk25;
  
  end

  always @(posedge CLK) begin
    vsync <= vsync_next; hsync <= hsync_next;
    v_counter <= vcount_next; h_counter <= hcount_next;
  end

  // h/v brojači 25 MHz
  always @(posedge clk25) begin
    if (h_counter == h_total - 1) hcount_next <= 0;
    else                          hcount_next <= h_counter + 1;
  end
  always @(posedge clk25) begin
    if (h_counter == h_total - 1) begin
      if (v_counter == v_total - 1) vcount_next <= 0;
      else                          vcount_next <= v_counter + 1;
    end
  end

  //  CRTANJE ploče
  always @(posedge CLK) begin
    // okviri/linije 
    if (((h_counter >= 110 && h_counter <= 120) && (v_counter >= 40 && v_counter <= 440)) ||
        ((h_counter >= 520 && h_counter <= 530) && (v_counter >= 40 && v_counter <= 440)) ||
        ((v_counter >= 30 && v_counter <= 40)  && (h_counter >= 110 && h_counter <= 530)) ||
        ((v_counter >= 440 && v_counter <= 450) && (h_counter >= 110 && h_counter <= 530))) begin
      zelena <= 1; plava <= 1; crvena <= 1;
    end
    else if (((h_counter >= 169 && h_counter <= 170) && (v_counter >= 40 && v_counter <= 440)) ||
             ((h_counter >= 219 && h_counter <= 220) && (v_counter >= 40 && v_counter <= 440)) ||
             ((h_counter >= 269 && h_counter <= 270) && (v_counter >= 40 && v_counter <= 440)) ||
             ((h_counter >= 319 && h_counter <= 320) && (v_counter >= 40 && v_counter <= 440)) ||
             ((h_counter >= 369 && h_counter <= 370) && (v_counter >= 40 && v_counter <= 440)) ||
             ((h_counter >= 419 && h_counter <= 420) && (v_counter >= 40 && v_counter <= 440)) ||
             ((h_counter >= 469 && h_counter <= 470) && (v_counter >= 40 && v_counter <= 440))) begin
      zelena <= 1; plava <= 1; crvena <= 1;
    end
    else if (((h_counter >= 120 && h_counter <= 520) && (v_counter >= 89  && v_counter <= 90 )) ||
             ((h_counter >= 120 && h_counter <= 520) && (v_counter >= 139 && v_counter <= 140)) ||
             ((h_counter >= 120 && h_counter <= 520) && (v_counter >= 189 && v_counter <= 190)) ||
             ((h_counter >= 120 && h_counter <= 520) && (v_counter >= 239 && v_counter <= 240)) ||
             ((h_counter >= 120 && h_counter <= 520) && (v_counter >= 289 && v_counter <= 290)) ||
             ((h_counter >= 120 && h_counter <= 520) && (v_counter >= 339 && v_counter <= 340)) ||
             ((h_counter >= 120 && h_counter <= 520) && (v_counter >= 389 && v_counter <= 390))) begin
      zelena <= 1; plava <= 1; crvena <= 1;
    end
    else begin
      crvena <= 0; zelena <= 0; plava <= 0;
    end

    // nacrtaj figuru koja stoji na ovom tile-u 
    begin : DRAW_PIECE
      integer i;
      reg hit; reg [3:0] ht_kind;
      hit = 1'b0; ht_kind = 4'd0;
      if (inside_board) begin
        for (i=0; i<32; i=i+1)
          if (!hit && pos[i] != NONE && pos[i][6:0] == tile_idx) begin
  hit = 1'b1; ht_kind = kind[i];
end

        if (hit && piece_on(ht_kind, local_x, local_y)) begin
          if (ht_kind <= 4'd6) begin
            crvena<=1; zelena<=1; plava<=1;      // bijela
          end else begin
            crvena<=0; zelena<=0; plava<=1;      // crna (plavo)
          end
        end
      end
    end
	 
//CRTANJE VIZUALNIH LINIJA "TAJMERA" 
// ŽUTA (bijeli) - lijevo (UVIJEK VIDLJIVA)
if ( (v_counter == (Y0 + line_y_white)) &&
     (h_counter >= LINE_LEFT_X1 && h_counter <= LINE_LEFT_X2) ) begin
  crvena <= 1; zelena <= 1; plava <= 0;   // žuta
end

// CRVENA (crni) - desno (UVIJEK VIDLJIVA)
if ( (v_counter == (Y0 + line_y_black)) &&
     (h_counter >= LINE_RIGHT_X1 && h_counter <= LINE_RIGHT_X2) ) begin
  crvena <= 1; zelena <= 0; plava <= 0;   // crvena
end


    // Highlighter = okvir 2 px, boja ovisi o tome tko je na potezu
if (inside_board && (tile_idx == cur_idx)) begin
  if (local_x < 2 || local_x > 47 || local_y < 2 || local_y > 47) begin
    if (turn_white) begin
      // bijeli na potezu › ŽUTI okvir
      crvena <= 1; zelena <= 1; plava <= 0;
    end else begin
      // crni na potezu › CRVENI okvir
      crvena <= 1; zelena <= 0; plava <= 0;
    end
  end
end
end

  // sync signali
  always @(posedge clk25) begin
    hsync_next <= (h_counter >= (h_display + h_frontporch) &&
                   h_counter <= (h_display + h_frontporch + h_syncwidth - 1));
    vsync_next <= (v_counter >= (v_display + v_frontporch) &&
                   v_counter <= (v_display + v_frontporch + v_syncwidth - 1));
  end

  assign VGA_H = ~hsync;
  assign VGA_V = ~vsync;
  assign VGA_G = zelena;
  assign VGA_B = plava;
  assign VGA_R = crvena;

endmodule
