# Pentagram (Summon) for the Commodore 64

A 6502 port of the graphics from the "Summon" mode (`PentaStar.java`). It draws a
pentagram whose edges are traced by 1–7 orbiting trail points. The star grows,
its loops unwind as the swirl speed decays, and then it settles while the cell
colours flicker.

- `pentagram.asm` is the program (ACME syntax).
- `gen_tables.py` generates `tables.asm`, which holds the sine, log2 and atan
  tables and the star edge constants.

Build and run:

    python3 gen_tables.py
    acme pentagram.asm          # -> pentagram.prg
    x64sc pentagram.prg

Sound: the Android drone (`AmbilectricSynth`) is recreated on the SID. It
has two sawtooth hums at 61 and 52 Hz that beat against each other and swell
at their own rates, quiet noise static, and random chirps at 800-1600 Hz
about once a second. It fades in over 10 seconds. The program detects PAL or
NTSC at start-up and tunes the pitches for that machine's clock. The
recorded voice clips from the Android app aren't included.

Each summon starts as a crisp pentagram that grows, then unfolds into the
trail loops. On the phone, the folding comes from moving the device (`dmove`
in `PentaStar.java`). Here it plays automatically, and you can control it
yourself with the + and - keys.

Joystick in port 2: up/down changes the number of trails, left/right changes
the swirl speed, and fire summons again. Keys: + / - unfold and fold the star,
and RUN/STOP returns to BASIC.
