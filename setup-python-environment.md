# Setup MicroPython Environment

Set up virtual environment...

```shell
python3 -m venv .
```

...activate automagically (in future) with direnv:

```shell
sudo apt-get install direnv
echo source bin/activate > .envrc; direnv allow .
```

## Initial (development) Setup

Manually install the required packages:

```shell
pip install Flask
```

Install dependencies:

```shell
pip install -r requirements.txt
```

## Freeze the dependencies

You can _freeze_ your local development dependencies with:

```shell
pip freeze > requirements.txt
```
