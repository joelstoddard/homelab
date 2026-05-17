.POSIX:
.PHONY: *
.EXPORT_ALL_VARIABLES:

LIMIT ?= 
TAGS ?= 
VERBOSITY ?= 
EXTRA_VARS ?=
VENV ?= .venv

default: ansible

help:
	@echo "Setup Homelab environment."
	@echo "Available options:"
	@echo "  help     	     - Show this help message."
	@echo "  bootstrap-secrets - Interactively write the operator's age key + NetBox env."
	@echo "  build    	     - Build the dev environment."
	@echo "  dev	  	     - Activate the dev environment."
	@echo "  lint     	     - Check repository syntax."
	@echo "  check		     - Perform a dry run."
	@echo "  apply		     - Build homelab."
	@echo "  ansible	     - Run ansible playbooks."
	@echo "  terraform	     - Run terraform."
	@echo "  clean		     - Clean temporary files."

bootstrap-secrets:
	./bootstrap-secrets.sh $(if $(FORCE),--force)

build:
	make -C ansible build && \
	make -C api build && \
	make -C kubernetes build && \
	make -C tailscale build && \
	make -C terraform build

dev:
	make -C ansible dev && \
	make -C api dev && \
	make -C kubernetes dev && \
	make -C tailscale dev && \
	make -C terraform dev

lint:
	make -C ansible lint && \
	make -C api lint && \
	make -C kubernetes lint && \
	make -C tailscale lint && \
	make -C terraform lint

check:
	make -C ansible check && \
	make -C api check && \
	make -C kubernetes check && \
	make -C tailscale check && \
	make -C terraform check

apply:
	make -C ansible apply && \
	make -C api apply && \
	make -C kubernetes apply && \
	make -C tailscale apply && \
	make -C terraform apply

ansible:
	make -C ansible

terraform:
	make -C terraform

clean:
	make -C ansible clean && \
	make -C api clean && \
	make -C kubernetes clean && \
	make -C tailscale clean && \
	make -C terraform clean