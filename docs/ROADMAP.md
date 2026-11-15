# Roadmap

*Last updated: November 2026*

Seeded at onboarding from the README's Known Issues and a first read of `app.py`.
Safety of the burn path comes first, because the kiosk runs `avrdude` and `shutdown` as root on a Raspberry Pi.

```mermaid
%%{init: {
  "theme": "base",
  "themeVariables": {
    "cScale0": "#e8f5e9",
    "cScaleLabel0": "#2e7d32",
    "cScale1": "#c8f7c5",
    "cScaleLabel1": "#1b5e20",
    "cScale2": "#fff3cd",
    "cScaleLabel2": "#7a5a00",
    "cScale3": "#e3f2fd",
    "cScaleLabel3": "#0d47a1"
  }
}}%%

timeline
    title AVR Burner Roadmap

    Ready     : No items yet

    Near term : Parse instructions.json with json instead of eval
              : Configurable avrdude bit clock (-B 125kHz for cheap USBasp)
              : Migrate from venv + requirements.txt to uv

    Mid term  : pytest coverage for routes with avrdude mocked (after uv migration)
              : Run avrdude asynchronously with progress feedback

    Long term : Drop root for avrdude via udev rules for the USBasp
