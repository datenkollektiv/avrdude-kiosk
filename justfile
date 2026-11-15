# List available recipes
default:
    @just --list

# Install pinned dependencies into the active venv
install:
    pip install -r requirements.txt

# Freeze the current venv into requirements.txt
freeze:
    pip freeze > requirements.txt

# Run the AVR Burner web UI on http://localhost:5001
run:
    python3 app.py

# Byte-compile the Python sources to catch syntax errors
check:
    python3 -m py_compile app.py config.example.py

# Read the fuses of the connected MCU to stdout
fuses part="m328p" programmer="usbasp":
    avrdude -c {{programmer}} -p {{part}} -U lfuse:r:-:h -U hfuse:r:-:h -U efuse:r:-:h

import? '.devcontainer/yolo.just'
