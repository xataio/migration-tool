# test/Makefile — Test harness for the migration tool
#
# Required env vars: SRC, TGT (PostgreSQL connection strings)
# Optional: SKIP_CONFIRM=1 to skip the load_data confirmation prompt

VENV := .venv
PYTHON := $(VENV)/bin/python

ifndef SRC
$(error SRC is not set. Export SRC=postgresql://... pointing to the source database)
endif
ifndef TGT
$(error TGT is not set. Export TGT=postgresql://... pointing to the target database)
endif

.PHONY: load_data test long-test test-full

$(VENV): requirements.txt
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install -r requirements.txt

load_data:
ifndef SKIP_CONFIRM
	@echo "This will load seed.sql into the SOURCE database ($$SRC)."
	@echo "This may take a long time and will create/overwrite tables."
	@read -p "Continue? [y/N] " confirm && [ "$$confirm" = "y" ] || (echo "Aborted."; exit 1)
endif
	psql "$(SRC)" -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
	psql "$(SRC)" -f seed.sql

test: $(VENV)
	$(PYTHON) -m pytest test_functional.py -v -s --timeout=900

long-test: $(VENV)
	$(PYTHON) -m pytest test_migration.py -v -s

test-full: $(VENV)
	$(PYTHON) -m pytest test_functional.py test_migration.py -v -s --timeout=900
