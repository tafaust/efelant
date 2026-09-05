EXTENSION = efelant_rest
MODULE_big = efelant_rest
DATA = efelant_rest--1.0.sql
OBJS = efelant_rest.o
PG_CPPFLAGS = -I$(srcdir)/../common
PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
