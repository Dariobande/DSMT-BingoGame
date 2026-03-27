# Makefile

REBAR = rebar3

.PHONY: all compile clean shell cluster

all: compile

compile:
	$(REBAR) compile

clean:
	$(REBAR) clean
	rm -rf _build

shell: compile
	$(REBAR) shell

# Comando utility per pulire il database locale (Mnesia) se serve resettare
clean-db:
	rm -rf Mnesia.*