from flask import Flask, render_template, request, jsonify, redirect, url_for
import subprocess

import importlib

config = {}
try:
    module = importlib.import_module('config')
    for key in dir(module):
        if not key.startswith("__"):  # Ignore built-in Python attributes
            config[key] = getattr(module, key)
except ModuleNotFoundError:
    print("No 'config.py' found, using defaults")
    config['AVRDUDE_COMMAND'] = 'sudo avrdude'
    config['AVR_PROGRAMMER'] = 'usbasp'
    config['SHUTDOWN_COMMAND'] = 'sudo shutdown -h now'
    config['PORT'] = '5001'
    config['LOGO'] = 'images/BROTEC.webp'

print("configuration:" + str(config))

app = Flask(__name__)

map_mcu_full_name_to_AVR_part = {
    'ATmega328P': 'm328p',
    'ATmega168PA': 'm168pa',
    'ATmega88PA': 'm88pa'
}

page_data = {
    'selected_mcu': 'ATmega328P',
    'hex_file': 'output.hex',
    'logo': config['LOGO'],
}

@app.route('/')
def home():
    return render_template('index.html', **page_data)

@app.route('/shutdown', methods=['POST'])
def shutdown():
    command = config['SHUTDOWN_COMMAND']
    print(command)

    process = subprocess.Popen(command.split(), stdout=subprocess.PIPE)
    process.communicate()

    page_data['action'] = 'shutdown'
    return render_template('index.html', **page_data)

@app.route('/update-selected-mcu', methods=['POST'])
def update_selected_mcu():
    selected_mcu = request.json.get('selectedMCU')
    # Update the selectedMCU variable here
    page_data['selected_mcu'] = selected_mcu

    print("Selected MCU changed to: " + selected_mcu)

    return jsonify(success=True)

@app.route('/download')
def download():
    # load file `instructions.json` into dictionary
    file = open('instructions.json', 'r')
    instructions = file.read()

    file.close()
    instructionsJson = eval(instructions)

    # extract the selected MCU and other target values from the instructions file
    page_data['instructions'] = instructions
    for key, value in map_mcu_full_name_to_AVR_part.items():
        if value == instructionsJson['part']:
            page_data['selected_mcu'] = key
            break
    page_data['target_low_fuse'] = instructionsJson['lfuse']
    page_data['target_high_fuse'] = instructionsJson['hfuse']
    page_data['target_ext_fuse'] = instructionsJson['efuse']
    page_data['hex_file'] = instructionsJson['file']

    page_data['action'] = 'download'
    return render_template('index.html', **page_data)

@app.route('/read-fuses', methods=['POST'])
def read_fuses():
    selected_mcu = page_data['selected_mcu']

    avrdude_part = map_mcu_full_name_to_AVR_part[selected_mcu]
    print("Selected MCU: " + selected_mcu + " (" + avrdude_part + ")")

    # Assemble `avrdude` command here
    command = config['AVRDUDE_COMMAND'] + " -c " + config['AVR_PROGRAMMER'] + " -p " + avrdude_part + " -U lfuse:r:-:h -U hfuse:r:-:h -U efuse:r:-:h"
    print(command)

    process = subprocess.Popen(command.split(), stdout=subprocess.PIPE)
    output, error = process.communicate()

    low_fuse = None
    high_fuse = None
    ext_fuse = None

    if output is not None and len(output) > 0:
        fuses = output.decode('utf-8').splitlines()
        low_fuse = fuses[0] if len(fuses) > 0 else None
        high_fuse = fuses[1] if len(fuses) > 1 else None
        ext_fuse = fuses[2] if len(fuses) > 2 else None
    else:
        process = subprocess.Popen(command.split(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        output, error = process.communicate()
        error = output.decode('utf-8')

    page_data['selected_mcu'] = selected_mcu
    page_data['low_fuse'] = low_fuse
    page_data['high_fuse'] = high_fuse
    page_data['ext_fuse'] = ext_fuse
    page_data['error'] = error

    page_data['action'] = 'read-fuses'
    return render_template('index.html', **page_data)

@app.route('/burn-low-fuse', methods=['POST'])
def burn_low_fuse():
    selected_mcu = page_data['selected_mcu']

    avrdude_part = map_mcu_full_name_to_AVR_part[selected_mcu]
    print("Selected MCU: " + selected_mcu + " (" + avrdude_part + ")")
    print("Target LOW fuse: " + page_data['target_low_fuse'])

    # Assemble `avrdude` command here
    command = config['AVRDUDE_COMMAND'] + " -c " + config['AVR_PROGRAMMER'] + " -p " + avrdude_part + " -U lfuse:w:" + page_data['target_low_fuse'] + ":m"
    print(command)

    process = subprocess.Popen(command.split(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    output, error = process.communicate()

    # if output contains the sting 'avrdude error' then we have an error
    if output is not None and len(output) > 0:
        if 'avrdude error' in output.decode('utf-8'):
            page_data['output'] = None
            page_data['error'] = output.decode('utf-8')
        else:
            page_data['output'] = output.decode('utf-8')
            page_data['error'] = None

    page_data['action'] = 'burn-fuse'
    return render_template('index.html', **page_data)

@app.route('/read-flash', methods=['POST'])
def read_flash():
    selected_mcu = page_data['selected_mcu']

    avrdude_part = map_mcu_full_name_to_AVR_part[selected_mcu]
    print("Selected MCU: " + selected_mcu + " (" + avrdude_part + ")")
    print("Target file: " + page_data['hex_file'])

    # Assemble `avrdude` command here
    command = config['AVRDUDE_COMMAND'] + " -c " + config['AVR_PROGRAMMER'] + " -p " + avrdude_part + " -U flash:r:backup_" + page_data['hex_file'] + ":i"
    print(command)

    process = subprocess.Popen(command.split(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    output, error = process.communicate()

    # if output contains the sting 'avrdude error' then we have an error
    if output is not None and len(output) > 0:
        if 'avrdude error' in output.decode('utf-8'):
            page_data['output'] = None
            page_data['error'] = output.decode('utf-8')
        else:
            page_data['output'] = output.decode('utf-8')
            page_data['error'] = None

    page_data['action'] = 'flash'
    return render_template('index.html', **page_data)

@app.route('/flash', methods=['POST'])
def flash():
    selected_mcu = page_data['selected_mcu']

    avrdude_part = map_mcu_full_name_to_AVR_part[selected_mcu]
    print("Selected MCU: " + selected_mcu + " (" + avrdude_part + ")")
    print("Target file: " + page_data['hex_file'])

    # Assemble `avrdude` command here -U flash:r|w|v:<filename>[:format]:
    # we omit the format parameter, so avrdude will use the default ihex format
    command = config['AVRDUDE_COMMAND'] + " -c " + config['AVR_PROGRAMMER'] + " -p " + avrdude_part + " -U flash:w:" + page_data['hex_file']
    print(command)

    process = subprocess.Popen(command.split(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    output, error = process.communicate()

    # if output contains the sting 'avrdude error' then we have an error
    if output is not None and len(output) > 0:
        if 'avrdude error' in output.decode('utf-8'):
            page_data['output'] = None
            page_data['error'] = output.decode('utf-8')
        else:
            page_data['output'] = output.decode('utf-8')
            page_data['error'] = None

    page_data['action'] = 'flash'
    return render_template('index.html', **page_data)

if __name__ == '__main__':
    app.run(debug=True, port=config['PORT'])
