EXTENSION = efelant_grpc
MODULE_big = efelant_grpc
DATA = efelant_grpc--1.0.sql
OBJS = efelant_grpc.o
PG_CPPFLAGS = -I$(srcdir)/../common
PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
