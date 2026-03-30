# Makefile

.PHONY: all compile clean clean-db

all: compile

compile:
	erlc -I include/ \
	-pa deps/jsx/ebin \
	-pa deps/cowboy/ebin \
	-pa deps/cowboy/deps/cowlib/ebin \
	-pa deps/cowboy/deps/ranch/ebin \
	-o ebin/ src/*.erl

clean:
	rm ebin/*.beam

# Comando utility per pulire il database locale (Mnesia) se serve resettare
clean-db:
	rm -r Mnesia.*