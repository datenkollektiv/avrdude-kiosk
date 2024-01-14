# Example configuration file for the AVR Burner
AVRDUDE_COMMAND = "avrdude"
# use `avrdude -c "?"` to get a list of supported programmers
# usbasp             = USBasp ISP and TPI programmer
# avrisp             = Atmel AVR ISP
AVR_PROGRAMMER = "usbasp"
SHUTDOWN_COMMAND = "echo 'shutdown skipped'"
PORT = "5001"
LOGO = "images/burning-atmega.webp"
