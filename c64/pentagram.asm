; ---------------------------------------------------------------------------
; Computational Demonology -- "Summon" pentagram (PentaStar) for the C64
;
; A port of the graphics from PentaStar.java: a pentagram whose edges are
; traced by a walking point, with 1..7 "trail" points orbiting it. Each trail
; orbits at radius r/(3p), and its phase depends on the walker's angle from
; the centre, so the trails draw looping spirograph-like lines around the star.
; As in the original, the star grows from nothing and its loops unwind while
; the "modspeed" decays, then it settles. Random colour flicker per 8x8 cell
; stands in for the original's random per-segment paint.
;
; Hires bitmap, double buffered (VIC bank 0: $2000/$0400, bank 1: $6000/$4400).
;
; Joystick in port 2 (replaces touch):
;   up/down     more/fewer trails (1..7)
;   left/right  slower/faster swirl (resets the unwinding)
;   fire        summon again (restart the growth)
; Keys:
;   + / -       unfold / fold the trails (the phone's tilt-driven "dmove")
;   RUN/STOP    return to BASIC
;
;
; Sound: the Android drone (AmbilectricSynth) on the SID -- two sawtooth hums
; at 61 and 52 Hz swelling at their own rates, quiet noise static, and short
; random chirps at 800-1600 Hz.
;
; Each summon starts as a crisp pentagram (dmove 0) that grows, then unfolds
; into the trail loops (dmove 1). On the phone dmove follows the device's
; motion; here it is clamped to -1..1 so the trails stay on screen.
;
; Build:  python3 gen_tables.py && acme pentagram.asm   ->  pentagram.prg
; Run:    LOAD"PENTAGRAM",8,1 / RUN   (or x64sc pentagram.prg)
; ---------------------------------------------------------------------------

!to "pentagram.prg", cbm

; --- constants -------------------------------------------------------------
CX      = 128           ; centre x in logical coordinates (screen x = x+32)
CY      = 92            ; centre y
RMAX    = 76            ; final star radius
FLOOR   = $4d           ; modspeed minimum, 0.3 in 8.8 fixed point
SPDSTEP = $33           ; 0.2 in 8.8
UNFOLDR = 57            ; radius at which the automatic unfold starts

SYTAB   = $8000         ; 7 pages: trail y offset by angle, per trail
SXTAB   = $8800         ; 7 pages: trail x offset by angle, per trail
TTAB    = $9000         ; 7 pages: trail angle by walker angle, per trail
sqlo    = $c000         ; quarter squares floor(n*n/4), n = 0..511
sqhi    = $c200
rowlo   = $c400         ; bitmap row address (includes the 32 px offset)
rowhi0  = $c500         ;   buffer 0 ($2000)
rowhi1  = $c600         ;   buffer 1 ($6000)

; --- zero page -------------------------------------------------------------
r       = $02           ; current radius
tabr    = $03           ; radius the trail offset tables were built for
mspd    = $04           ; modspeed, 8.8
speed   = $06           ; base speed, 8.8
trails  = $08
k1      = $09           ; 15 * modspeed, 8.8
kp      = $0b           ; 15 * modspeed * p, 8.8 (integer part mod 256)
t0      = $0d
t1      = $0e
t2      = $0f
tmp     = $10
tmp2    = $11
ptr     = $12
ptr2    = $14
ma      = $16
mb      = $17
prodlo  = $18
prodhi  = $19
sqtlo   = $1a
sqthi   = $1b
edge    = $1c
xlo     = $1d           ; walker position, 8.8
xhi     = $1e
ylo     = $1f
yhi     = $20
xinclo  = $21
xinchi  = $22
yinclo  = $23
yinchi  = $24
nsteps  = $25
first   = $26
r2      = $27           ; walker angle + 64 + 43 (pi/3), binary degrees
pidx    = $28
ptrT    = $29
ptrSX   = $2b
ptrSY   = $2d
ax      = $2f
ay      = $30
sgn     = $31
lastx   = $32           ; 7 bytes
lasty   = $3a           ; 7 bytes
lx      = $41           ; line from (lx,ly) to (lx2,ly2)
ly      = $42
lx2     = $43
ly2     = $44
ddx     = $45
ddy     = $46
sxv     = $47
syv     = $48
err     = $49
cnt     = $4a
pp      = $4b           ; plot pointer
amp     = $4d
cval    = $4e
backbuf = $4f           ; buffer being drawn: 0 or 1
changed = $50
acc0    = $51
acc1    = $52
acc2    = $53
inc0    = $54
inc1    = $55
dm      = $56           ; dmove in eighths, -8..8
autounf = $57           ; 1 while the automatic unfold is pending
amplo   = $58           ; trail amplitude fraction (amp is the integer part)
dsign   = $59           ; $80 if dm < 0
mval    = $5a
adm     = $5b           ; |dm|

joyprev = $70           ; used by the IRQ only
joypend = $71           ; joystick presses latched by the IRQ
ip0     = $72
ip1     = $74
icnt    = $76
seed    = $77
itmp    = $78
stoppend = $79          ; RUN/STOP latched by the IRQ
keyprev = $7a
keypend = $7b           ; + / - presses latched by the IRQ
v1cnt   = $7c           ; drone sequencer, IRQ only
v2cnt   = $7d
v2ctl   = $7e
aphase  = $7f
chirpon = $80
seedhi  = $81
volcnt  = $82
mvol    = $83
v1flo   = $84           ; voice 1 drone frequency for this machine
v1fhi   = $85
chbase  = $86           ; chirp frequency high byte: base and range
chrange = $87

zpsave  = $c800         ; BASIC's zero page $02-$8f, restored on exit

; --- BASIC stub: 10 SYS2061 ------------------------------------------------
        * = $0801
        !word +, 10
        !byte $9e
        !text "2061"
        !byte 0
+       !word 0

; --- init ------------------------------------------------------------------
start   sei
        tsx                     ; remember how to get back to BASIC
        stx savesp
        ldx #$8e                ; save $02-$8f
-       lda $01,x
        sta zpsave-1,x
        dex
        bne -
        lda #0
        sta $d020
        sta $d021
        lda #$3b                ; bitmap mode, screen on
        sta $d011
        lda #$08                ; hires, 40 columns
        sta $d016
        lda #$18                ; screen at +$0400, bitmap at +$2000
        sta $d018
        jsr detect
        jsr sidinit
        lda #$ff                ; no keyboard rows selected: port A = joystick 2
        sta $dc00

        jsr gensq
        jsr genrows

        ldx #0                  ; cyan on black in both screens
        lda #$30
-       sta $0400,x
        sta $0500,x
        sta $0600,x
        sta $0700,x
        sta $4400,x
        sta $4500,x
        sta $4600,x
        sta $4700,x
        inx
        bne -
        jsr clear0
        jsr clear1

        lda $dd00               ; show buffer 0, draw into buffer 1
        ora #3
        sta $dd00
        lda #1
        sta backbuf
        jsr setbuf

        lda #0
        sta joyprev
        sta joypend
        sta stoppend
        sta keyprev
        sta keypend
        lda #1
        sta seed
        lda #0
        sta seedhi
        lda #<irq
        sta $0314
        lda #>irq
        sta $0315
        cli

        lda #3
        sta trails
        lda #$80                ; speed = 1.5
        sta speed
        lda #$01
        sta speed+1
restart jsr summon
        lda speed
        sta mspd
        lda speed+1
        sta mspd+1

; --- main loop -------------------------------------------------------------
frame   lda r
        cmp tabr
        beq +
        jsr buildamp
        lda r
        sta tabr
+       jsr buildtheta
        jsr clearback
        jsr drawstar
        jsr flip

        lda #0
        sta changed
        ; grow: r += max(1, (RMAX-r)/4)
        lda r
        cmp #RMAX
        bcs +++
        lda #RMAX
        sec
        sbc r
        lsr
        lsr
        bne +
        lda #1
+       clc
        adc r
        sta r
        inc changed
+++
        ; decay: modspeed -= modspeed/8, but not below FLOOR
        lda mspd
        sta t0
        lda mspd+1
        sta t1
        ldx #3
-       lsr t1
        ror t0
        dex
        bne -
        sec
        lda mspd
        sbc t0
        sta t0
        lda mspd+1
        sbc t1
        sta t1
        bne +
        lda t0
        cmp #FLOOR
        bcs +
        lda #FLOOR
        sta t0
+       lda t0
        cmp mspd
        bne +
        lda t1
        cmp mspd+1
        beq ++
+       inc changed
        lda t0
        sta mspd
        lda t1
        sta mspd+1
++
        ; unfold: dmove 0 -> 1 once the star has mostly grown
        lda autounf
        beq +
        lda r
        cmp #UNFOLDR
        bcc +
        inc dm
        lda #$ff
        sta tabr
        inc changed
        lda dm
        cmp #8
        bne +
        lda #0
        sta autounf
+
        jsr handlejoy
        jsr checkstop
        lda changed
        beq idle
        jmp frame
idle    jsr handlejoy           ; star has settled: only the IRQ flicker runs
        jsr checkstop
        lda changed
        beq idle
        jmp frame

; --- RUN/STOP: put everything back and return to BASIC ---------------------
        !zone checkstop
checkstop
        lda stoppend
        bne +
        rts
+       sei
        lda #<$ea31             ; KERNAL IRQ handler
        sta $0314
        lda #>$ea31
        sta $0315
        lda #0                  ; silence the SID
        sta $d418
        sta $d404
        sta $d40b
        sta $d412
        lda $dd00               ; VIC bank 0
        ora #3
        sta $dd00
        lda #$1b                ; text mode, default screen and charset
        sta $d011
        lda #$c8
        sta $d016
        lda #$15
        sta $d018
        lda #14
        sta $d020
        lda #6
        sta $d021
        lda #$7f                ; wait for RUN/STOP to be released,
        sta $dc00               ; or BASIC would see it and print BREAK
-       lda $dc01
        bpl -
        ldx #$8e
-       lda zpsave-1,x
        sta $01,x
        dex
        bne -
        ldx savesp
        txs
        cli
        jsr $e544               ; clear screen
        rts                     ; back to the SYS in BASIC

savesp  !byte 0

; --- joystick --------------------------------------------------------------
        !zone handlejoy
handlejoy
        sei
        ldx #0
        lda keypend
        stx keypend
        sta tmp2
        lda joypend
        stx joypend
        cli
        sta tmp
        lda tmp2
        beq .joy
        inc changed             ; a key takes over from the automatic unfold
        lda #0
        sta autounf
        lda #$ff
        sta tabr
        lsr tmp2                ; +: unfold
        bcc +
        lda dm
        cmp #8
        beq +
        inc dm
+       lsr tmp2
        lsr tmp2
        lsr tmp2                ; -: fold
        bcc .joy
        lda dm
        cmp #$f8
        beq .joy
        dec dm
.joy    lda tmp
        beq .done
        inc changed
        lsr tmp                 ; up: more trails
        bcc +
        lda trails
        cmp #7
        bcs +
        inc trails
        lda #$ff                ; offset tables need building for the new trail
        sta tabr
+       lsr tmp                 ; down: fewer trails
        bcc +
        lda trails
        cmp #2
        bcc +
        dec trails
+       lsr tmp                 ; left: slower
        bcc ++
        sec
        lda speed
        sbc #SPDSTEP
        sta speed
        lda speed+1
        sbc #0
        sta speed+1
        bne +
        lda #0
        sta speed
        lda #1
        sta speed+1
+       jsr setmspd
++      lsr tmp                 ; right: faster
        bcc ++
        clc
        lda speed
        adc #SPDSTEP
        sta speed
        lda speed+1
        adc #0
        sta speed+1
        cmp #3
        bcc +
        lda #0
        sta speed
        lda #3
        sta speed+1
+       jsr setmspd
++      lsr tmp                 ; fire: summon again
        bcc .done
        jsr summon
.done   rts

summon  lda #1                  ; start small, folded, swirling at full speed
        sta r
        sta autounf
        lda #0
        sta dm
        lda #$ff
        sta tabr

setmspd lda speed
        sta mspd
        lda speed+1
        sta mspd+1
        rts

; --- trail offset tables (only when r or dmove changes) -------------------
; SY_p[t] = trunc(A_p * sin t) + 1,  SX_p[t] = trunc(A_p * cos t) + 1,
; A_p = dmove * r / (3p), for the trails in use
        !zone buildamp
buildamp
        lda dm
        and #$80
        sta dsign
        lda dm
        bpl +
        eor #$ff
        clc
        adc #1
+       sta adm
        lda #0
        sta ptr
        sta ptr2
        sta pidx
.p      ldx pidx                ; amp.amplo = r * 256/(3p) * |dm| / 8
        lda recip3p,x
        tax
        lda r
        jsr mul
        lda prodlo
        sta t0
        lda prodhi
        sta t1
        lda t0
        ldx adm
        jsr mul
        lda prodlo
        sta acc0
        lda prodhi
        sta acc1
        lda t1
        ldx adm
        jsr mul
        clc
        lda acc1
        adc prodlo
        sta acc1
        lda prodhi
        adc #0
        sta acc2
        ldx #3
-       lsr acc2
        ror acc1
        ror acc0
        dex
        bne -
        lda acc0
        sta amplo
        lda acc1
        sta amp
        lda pidx
        clc
        adc #>SYTAB
        sta ptr+1
        lda pidx
        clc
        adc #>SXTAB
        sta ptr2+1
        ldy #0
.t      sty tmp                 ; P = amp.amplo * m,  A*|sin| ~= (P + P/256) / 256
        lda sinmag,y
        sta mval
        ldx amp
        jsr mul
        lda prodlo
        sta t0
        lda prodhi
        sta t1
        lda mval
        ldx amplo
        jsr mul
        clc
        lda t0
        adc prodhi
        sta t0
        bcc +
        inc t1
+       lda t0
        clc
        adc t1
        lda t1
        adc #0
        sta tmp2
        ldy tmp
        tya                     ; negative when sin < 0, flipped for dmove < 0
        and #$80
        eor dsign
        beq +
        lda #0
        sec
        sbc tmp2
        sta tmp2
+       lda tmp2
        clc
        adc #1
        sta (ptr),y
        sta tmp2
        tya                     ; cos t = sin (t+64): SX[t-64] = SY[t]
        sec
        sbc #64
        tay
        lda tmp2
        sta (ptr2),y
        ldy tmp
        iny
        bne .t
        inc pidx
        lda pidx
        cmp trails
        beq +
        jmp .p
+       rts

; --- trail angle tables (every frame) --------------------------------------
; trail p angle = (pi*p - rad2) * modspeed*15*p. In binary degrees with
; r2 = rad2 + 64:  angle = C_p - r2*K_p,  K_p = 15*modspeed*p,
;                  C_p = 64*(2p+1)*K_p  (mod 256)
        !zone buildtheta
buildtheta
        lda mspd
        sta t0
        lda mspd+1
        sta t1
        ldx #4
-       asl t0
        rol t1
        dex
        bne -
        sec
        lda t0
        sbc mspd
        sta k1
        lda t1
        sbc mspd+1
        sta k1+1
        lda #0
        sta kp
        sta kp+1
        sta ptr
        tax
.p      clc
        lda kp
        adc k1
        sta kp
        lda kp+1
        adc k1+1
        sta kp+1
        txa                     ; acc = (2p+1) * K_p, p = x+1
        asl
        clc
        adc #3
        sta cnt
        lda #0
        sta acc0
        sta acc1
-       clc
        lda acc0
        adc kp
        sta acc0
        lda acc1
        adc kp+1
        sta acc1
        dec cnt
        bne -
        lda acc1                ; C_p = bits 2..9 of acc
        and #3
        asl
        asl
        asl
        asl
        asl
        asl
        sta cval
        lda acc0
        lsr
        lsr
        ora cval
        sta cval
        txa
        clc
        adc #>TTAB
        sta ptr+1
        lda #0
        sta acc0
        sta acc1
        tay
-       lda cval
        sec
        sbc acc1
        sta (ptr),y
        clc
        lda acc0
        adc kp
        sta acc0
        lda acc1
        adc kp+1
        sta acc1
        iny
        bne -
        inx
        cpx #7
        bne .p
        rts

; --- draw the star into the back buffer ------------------------------------
        !zone drawstar
drawstar
        lda #0
        sta ptrT
        sta ptrSX
        sta ptrSY
        sta edge
.edge   ldx edge                ; start vertex x = CX + r*sin(edge*144)
        lda e_vxmag,x
        tax
        lda r
        jsr mul
        jsr addr
        ldx edge
        lda e_vxsgn,x
        bne +
        lda prodlo
        sta xlo
        lda prodhi
        clc
        adc #CX
        sta xhi
        jmp ++
+       lda #0
        sec
        sbc prodlo
        sta xlo
        lda #CX
        sbc prodhi
        sta xhi
++      ldx edge                ; start vertex y = CY + r*cos(edge*144)
        lda e_vymag,x
        tax
        lda r
        jsr mul
        jsr addr
        ldx edge
        lda e_vysgn,x
        bne +
        lda prodlo
        sta ylo
        lda prodhi
        clc
        adc #CY
        sta yhi
        jmp ++
+       lda #0
        sec
        sbc prodlo
        sta ylo
        lda #CY
        sbc prodhi
        sta yhi
++      ldx edge
        lda e_xinclo,x
        sta xinclo
        lda e_xinchi,x
        sta xinchi
        lda e_yinclo,x
        sta yinclo
        lda e_yinchi,x
        sta yinchi
        lda e_cnhi,x            ; steps = r * |dx| * fac
        tax
        lda r
        jsr mul
        lda prodlo
        sta nsteps
        ldx edge
        lda e_cnlo,x
        tax
        lda r
        jsr mul
        lda prodhi
        clc
        adc nsteps
        bne +
        lda #1
+       sta nsteps
        lda #1
        sta first

.step   jsr angle               ; angle from the centre, then advance
        sta r2
        clc
        lda xlo
        adc xinclo
        sta xlo
        lda xhi
        adc xinchi
        sta xhi
        clc
        lda ylo
        adc yinclo
        sta ylo
        lda yhi
        adc yinchi
        sta yhi

        ldx #0
.trail  txa
        clc
        adc #>TTAB
        sta ptrT+1
        txa
        clc
        adc #>SXTAB
        sta ptrSX+1
        txa
        clc
        adc #>SYTAB
        sta ptrSY+1
        ldy r2
        lda (ptrT),y
        tay
        lda (ptrSX),y
        clc
        adc xhi
        sta lx2
        lda (ptrSY),y
        clc
        adc yhi
        sta ly2
        lda first
        bne +
        lda lastx,x
        sta lx
        lda lasty,x
        sta ly
        lda lx2
        sta lastx,x
        lda ly2
        sta lasty,x
        stx pidx
        jsr line
        ldx pidx
        jmp ++
+       lda lx2
        sta lastx,x
        lda ly2
        sta lasty,x
++      inx
        cpx trails
        bne .trail
        lda #0
        sta first
        dec nsteps
        bne .step

        inc edge
        lda edge
        cmp #5
        beq +
        jmp .edge
+       rts

addr    clc                     ; prod += r  (so m=255 scales by exactly r)
        lda prodlo
        adc r
        sta prodlo
        bcc +
        inc prodhi
+       rts

; --- atan((y-CY)/(x-CX)) + pi/3 + 64, binary degrees -----------------------
        !zone angle
angle   lda #0
        sta sgn
        lda xhi
        sec
        sbc #CX
        bcs +
        eor #$ff
        adc #1
        inc sgn
+       sta ax
        lda yhi
        sec
        sbc #CY
        bcs +
        eor #$ff
        adc #1
        inc sgn
+       sta ay
        ldx ax
        beq .vert
        ldy ay
        beq .horiz
        lda log2tab,y
        sec
        sbc log2tab,x
        bcc .shallow
        tax                     ; |dy| >= |dx|: 64 - atan(dx/dy)
        lda #64
        sec
        sbc atantab,x
        jmp .have
.shallow
        eor #$ff
        adc #1
        tax
        lda atantab,x
        jmp .have
.vert   lda #64
        jmp .have
.horiz  lda #0
.have   ldx sgn
        cpx #1
        beq +
        clc                     ; same signs: positive angle
        adc #107
        rts
+       sta tmp
        lda #107
        sec
        sbc tmp
        rts

; --- unsigned 8x8 multiply: A * X -> prodhi:prodlo (clobbers Y) -------------
; a*b = sq(a+b) - sq(|a-b|), sq(n) = floor(n*n/4)
        !zone mul
mul     sta ma
        stx mb
        clc
        adc mb
        tay
        bcc +
        lda sqlo+256,y
        sta sqtlo
        lda sqhi+256,y
        sta sqthi
        jmp ++
+       lda sqlo,y
        sta sqtlo
        lda sqhi,y
        sta sqthi
++      lda ma
        sec
        sbc mb
        bcs +
        eor #$ff
        adc #1
+       tay
        lda sqtlo
        sec
        sbc sqlo,y
        sta prodlo
        lda sqthi
        sbc sqhi,y
        sta prodhi
        rts

; --- Bresenham line (lx,ly) -> (lx2,ly2) -----------------------------------
        !zone line
line    ldx #1                  ; (lx,ly) was plotted as the previous segment's end

        lda lx2
        sec
        sbc lx
        bcs +
        eor #$ff
        adc #1
        ldx #$ff
+       sta ddx
        stx sxv
        ldx #1
        lda ly2
        sec
        sbc ly
        bcs +
        eor #$ff
        adc #1
        ldx #$ff
+       sta ddy
        stx syv
        lda ddx
        cmp ddy
        bcc .ymaj
        lda ddx
        beq .done
        sta cnt
        lsr
        sta err
.xl     lda lx
        clc
        adc sxv
        sta lx
        lda err
        sec
        sbc ddy
        bcs +
        adc ddx
        sta err
        lda ly
        clc
        adc syv
        sta ly
        jmp ++
+       sta err
++      jsr plot
        dec cnt
        bne .xl
.done   rts
.ymaj   lda ddy
        sta cnt
        lsr
        sta err
.yl     lda ly
        clc
        adc syv
        sta ly
        lda err
        sec
        sbc ddx
        bcs +
        adc ddy
        sta err
        lda lx
        clc
        adc sxv
        sta lx
        jmp ++
+       sta err
++      jsr plot
        dec cnt
        bne .yl
        rts

plot    ldy ly
        cpy #200
        bcs +
        lda rowlo,y
        sta pp
plothi  lda rowhi0,y            ; operand patched by setbuf
        sta pp+1
        lda lx
        and #7
        tax
        lda lx
        and #$f8
        tay
        lda (pp),y
        ora bitmask,x
        sta (pp),y
+       rts

bitmask !byte $80,$40,$20,$10,$08,$04,$02,$01

; --- buffers ---------------------------------------------------------------
        !zone flip
flip
-       lda $d012               ; wait for the lower border
        cmp #$fb
        bne -
        lda backbuf
        beq +
        lda $dd00               ; show bank 1 ($4000), draw into bank 0
        and #$fc
        ora #2
        sta $dd00
        lda #0
        sta backbuf
        jmp setbuf
+       lda $dd00               ; show bank 0, draw into bank 1
        ora #3
        sta $dd00
        lda #1
        sta backbuf
setbuf  lda backbuf
        bne +
        lda #<rowhi0
        sta plothi+1
        lda #>rowhi0
        sta plothi+2
        rts
+       lda #<rowhi1
        sta plothi+1
        lda #>rowhi1
        sta plothi+2
        rts

        !zone clearback
clearback
        lda backbuf
        bne clear1
clear0  lda #0
        tax
-       !for i, 0, 31 { sta $2000 + i * 256, x }
        inx
        bne -
        rts
clear1  lda #0
        tax
-       !for i, 0, 31 { sta $6000 + i * 256, x }
        inx
        bne -
        rts

; --- one-time table setup --------------------------------------------------
        !zone gensq
gensq   lda #0                  ; sq(n) = n*n >> 2 via n*n += 2n+1
        sta acc0
        sta acc1
        sta acc2
        sta inc1
        sta ptr
        sta ptr2
        lda #1
        sta inc0
        lda #>sqlo
        sta ptr+1
        lda #>sqhi
        sta ptr2+1
        ldx #2
        ldy #0
-       lda acc0
        sta t0
        lda acc1
        sta t1
        lda acc2
        sta t2
        lsr t2
        ror t1
        ror t0
        lsr t2
        ror t1
        ror t0
        lda t0
        sta (ptr),y
        lda t1
        sta (ptr2),y
        clc
        lda acc0
        adc inc0
        sta acc0
        lda acc1
        adc inc1
        sta acc1
        lda acc2
        adc #0
        sta acc2
        clc
        lda inc0
        adc #2
        sta inc0
        bcc +
        inc inc1
+       iny
        bne -
        inc ptr+1
        inc ptr2+1
        dex
        bne -
        rts

        !zone genrows
genrows lda #<($2000 + 32)      ; row y: $2000 + 32 + (y/8)*320 + (y&7)
        sta ptr
        lda #>($2000 + 32)
        sta ptr+1
        ldy #0
-       tya
        and #7
        clc
        adc ptr
        sta rowlo,y
        lda ptr+1
        adc #0
        sta rowhi0,y
        clc
        adc #$40
        sta rowhi1,y
        tya
        and #7
        cmp #7
        bne +
        clc
        lda ptr
        adc #<320
        sta ptr
        lda ptr+1
        adc #>320
        sta ptr+1
+       iny
        cpy #200
        bne -
        rts

; --- IRQ: latch joystick and keys, flicker cell colours, drone ------------
        !zone irq
irq     lda $dc0d
        lda $dc00
        eor #$ff
        and #$1f
        sta itmp
        lda joyprev
        eor #$ff
        and itmp
        ora joypend
        sta joypend
        lda itmp
        sta joyprev
        lda #$df                ; keyboard column 5: + is row bit 0, - is bit 3
        sta $dc00
        lda $dc01
        eor #$ff
        and #$09
        sta itmp
        lda keyprev
        eor #$ff
        and itmp
        ora keypend
        sta keypend
        lda itmp
        sta keyprev
        lda #$7f                ; keyboard column 7: RUN/STOP is row bit 7
        sta $dc00
        lda $dc01
        bmi +
        lda #1
        sta stoppend
+       lda #$ff
        sta $dc00
        lda #24
        sta icnt
-       jsr irnd                ; recolour 24 random cells in both screens
        and #3
        ora #$04
        sta ip0+1
        ora #$40
        sta ip1+1
        jsr irnd
        sta ip0
        sta ip1
        jsr irnd
        and #7
        tax
        lda coltab,x
        ldy #0
        sta (ip0),y
        sta (ip1),y
        dec icnt
        bne -
        jsr drone
        jmp $ea81

; --- drone ------------------------------------------------------------------
; The SID has no per-voice volume, so the swells come from the envelopes:
; voice 1 is re-triggered every 5.9 s (rises to full, decays back to half);
; voice 2 is gated on/off every 3.45 s, and its 8 s attack is cut off at
; about 43% so, as on Android, it never gets louder than voice 1's quietest.
; Voice 3 is steady quiet noise (also the random source). A chirp moves
; voice 1 to a random 800-1600 Hz for one IRQ tick (~17 ms). The master
; volume fades in over 10 s, like GraphicDmn's synth.setVol ramp.
; SID pitch follows the CPU clock (PAL 985248 Hz, NTSC 1022727 Hz), so the
; frequency values are picked for the machine detected at start-up.
V1HALF  = 177           ; voice 1 retrigger period, in 2-tick steps (5.9 s)
V2HALF  = 104           ; voice 2 gate on/off time, in 2-tick steps (3.45 s)

; Fn = Hz * 16777216 / clock          PAL    NTSC
f61lo   !byte <1039, <1001      ; 61 Hz
f61hi   !byte >1039, >1001
f52lo   !byte <885, <853        ; 52 Hz
f52hi   !byte >885, >853
fchb    !byte $35, $33          ; 800 Hz high byte
fchr    !byte 53, 52            ; high bytes up to 1600 Hz

machine !byte 0                 ; 0 = PAL, 1 = NTSC

; Count raster lines: the last line is $137 on PAL (312 lines) and $106 or
; $105 on NTSC (263/262), so the low byte before the wrap tells them apart.
; Runs with interrupts off.
detect
-       lda $d012
--      cmp $d012
        beq --
        bmi -
        ldx #0
        cmp #$20
        bcs +
        inx
+       stx machine
        rts

sidinit ldx #$18
        lda #0
-       sta $d400,x
        dex
        bpl -
        ldx machine
        lda f61lo,x
        sta v1flo
        lda f61hi,x
        sta v1fhi
        lda fchb,x
        sta chbase
        lda fchr,x
        sta chrange
        lda v1flo               ; voice 1: 61 Hz sawtooth
        sta $d400
        lda v1fhi
        sta $d401
        lda #$ee                ; attack and decay ~2.4 s over the 50-100% swell
        sta $d405
        lda #$8c                ; sustain 8/15, release 3 s
        sta $d406
        lda f52lo,x             ; voice 2: 52 Hz sawtooth
        sta $d407
        lda f52hi,x
        sta $d408
        lda #$fc                ; attack 8 s (gated off at ~43%)
        sta $d40c
        lda #$fc                ; release 3 s
        sta $d40d
        lda #$ff                ; voice 3: noise static
        sta $d40e
        sta $d40f
        lda #$00                ; straight to sustain 4/15: no swell
        sta $d413
        lda #$4c
        sta $d414
        lda #0                  ; master volume fades in from 0, no filter
        sta mvol
        sta $d418
        lda #40
        sta volcnt
        lda #V1HALF
        sta v1cnt
        lda #V2HALF
        sta v2cnt
        lda #0
        sta aphase
        sta chirpon
        lda #$21                ; gate on: the attacks fade the drone in
        sta $d404
        sta $d40b
        sta v2ctl
        lda #$81
        sta $d412
        rts

drone   lda mvol                ; fade in: one volume step every 40 ticks
        cmp #15
        beq +
        dec volcnt
        bne +
        lda #40
        sta volcnt
        inc mvol
        lda mvol
        sta $d418
+       lda chirpon             ; end a chirp after one tick
        beq +
        lda v1flo
        sta $d400
        lda v1fhi
        sta $d401
        lda #0
        sta chirpon
        jmp ++
+       jsr irnd                ; ~1 chirp per second, as on Android
        cmp #4
        bcs ++
        jsr irnd
        and #$3f
        cmp chrange
        bcc +
        sbc chrange
+       clc
        adc chbase              ; 800-1600 Hz for this machine's clock
        sta $d401
        jsr irnd
        sta $d400
        inc chirpon
++      lda aphase              ; the swells step every other tick
        eor #1
        sta aphase
        beq .done
        dec v1cnt
        lda v1cnt
        cmp #1
        bne +
        lda #$20                ; gate voice 1 off for one step...
        sta $d404
+       lda v1cnt
        bne +
        lda #$21                ; ...then on again: attack from where it was
        sta $d404
        lda #V1HALF
        sta v1cnt
+       dec v2cnt
        bne .done
        lda v2ctl               ; toggle voice 2 between attack and release
        eor #1
        sta v2ctl
        sta $d40b
        lda #V2HALF
        sta v2cnt
.done   rts

irnd    lda seedhi          ; 16-bit xorshift (7,9,8), after John Metcalf
        lsr
        lda seed
        ror
        eor seedhi
        sta seedhi
        ror
        eor seed
        sta seed
        eor seedhi
        sta seedhi
        eor $d41b               ; plus SID noise; the state stays pure xorshift
        rts

coltab  !byte $30,$30,$30,$50,$30,$30,$b0,$30   ; mostly cyan, some green/grey

; --- constant tables -------------------------------------------------------
        !source "tables.asm"

        !if * > $2000 { !error "program overlaps the bitmap at $2000" }
