#!/bin/bash
# Run visualization script using virtual environment

cd "$(dirname "$0")"

if [ -d ".venv" ]; then
    source .venv/bin/activate
    python3 generate_visualizations.py
else
    echo "Virtual environment not found. Creating..."
    python3 -m venv .venv
    source .venv/bin/activate
    pip install matplotlib --quiet
    python3 generate_visualizations.py
fi
