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

Joystick in port 2: up/down changes the number of trails, left/right changes
the swirl speed, and fire summons again.
