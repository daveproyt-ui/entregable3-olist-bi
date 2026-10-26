-- =====================================================================
-- Entregable 2 · Data Mart Olist (Brazilian E-Commerce) en PostgreSQL
-- Script 01: creación del esquema y de las tablas del modelo dimensional
-- Granularidad de fact_ventas: UNA FILA = UN ÍTEM (producto) DENTRO DE UN PEDIDO
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS dm;
SET search_path TO dm, public;

DROP TABLE IF EXISTS fact_ventas        CASCADE;
DROP TABLE IF EXISTS dim_tiempo         CASCADE;
DROP TABLE IF EXISTS dim_cliente        CASCADE;
DROP TABLE IF EXISTS dim_producto       CASCADE;
DROP TABLE IF EXISTS dim_vendedor       CASCADE;
DROP TABLE IF EXISTS dim_pago           CASCADE;
DROP TABLE IF EXISTS dim_estado_pedido  CASCADE;

-- ---------------------------------------------------------------------
-- DIMENSIONES
-- ---------------------------------------------------------------------
CREATE TABLE dim_tiempo (
    tiempo_key         INTEGER      PRIMARY KEY,          -- formato YYYYMMDD
    fecha              DATE         NOT NULL UNIQUE,
    anio               SMALLINT     NOT NULL,
    trimestre          SMALLINT     NOT NULL CHECK (trimestre BETWEEN 1 AND 4),
    mes                SMALLINT     NOT NULL CHECK (mes BETWEEN 1 AND 12),
    nombre_mes         VARCHAR(12)  NOT NULL,
    anio_mes           CHAR(7)      NOT NULL,             -- 'YYYY-MM'
    dia                SMALLINT     NOT NULL,
    dia_semana         SMALLINT     NOT NULL CHECK (dia_semana BETWEEN 1 AND 7), -- 1 = lunes
    nombre_dia_semana  VARCHAR(12)  NOT NULL,
    es_fin_de_semana   BOOLEAN      NOT NULL
);

CREATE TABLE dim_cliente (
    cliente_key         SERIAL       PRIMARY KEY,
    customer_unique_id  VARCHAR(40)  NOT NULL UNIQUE,     -- clave natural (cliente real)
    ciudad              VARCHAR(80),
    estado              CHAR(2)
);

CREATE TABLE dim_producto (
    producto_key   SERIAL        PRIMARY KEY,
    product_id     VARCHAR(40)   NOT NULL UNIQUE,         -- clave natural
    categoria_pt   VARCHAR(80)   NOT NULL,                -- categoría original (portugués)
    categoria_en   VARCHAR(80)   NOT NULL,                -- categoría traducida
    peso_g         INTEGER       CHECK (peso_g IS NULL OR peso_g >= 0),
    volumen_cm3    NUMERIC(12,1) CHECK (volumen_cm3 IS NULL OR volumen_cm3 >= 0),
    num_fotos      SMALLINT
);

CREATE TABLE dim_vendedor (
    vendedor_key  SERIAL       PRIMARY KEY,
    seller_id     VARCHAR(40)  NOT NULL UNIQUE,           -- clave natural
    ciudad        VARCHAR(80),
    estado        CHAR(2)
);

-- Dimensión "junk": combina atributos de pago de baja cardinalidad
CREATE TABLE dim_pago (
    pago_key      SERIAL       PRIMARY KEY,
    tipo_pago     VARCHAR(20)  NOT NULL,                  -- credit_card, boleto, voucher, debit_card, no_definido, sin_pago
    rango_cuotas  VARCHAR(15)  NOT NULL,                  -- contado, 2-6 cuotas, 7-12 cuotas, 13+ cuotas, sin_pago
    UNIQUE (tipo_pago, rango_cuotas)
);

CREATE TABLE dim_estado_pedido (
    estado_key    SERIAL       PRIMARY KEY,
    order_status  VARCHAR(20)  NOT NULL UNIQUE,
    es_venta_valida BOOLEAN    NOT NULL                   -- FALSE para canceled / unavailable
);

-- ---------------------------------------------------------------------
-- TABLA DE HECHOS
-- Granularidad: una fila por ítem de pedido (order_id + order_item_id)
-- ---------------------------------------------------------------------
CREATE TABLE fact_ventas (
    order_id            VARCHAR(40)   NOT NULL,           -- dimensión degenerada
    order_item_id       SMALLINT      NOT NULL,           -- n.º del ítem dentro del pedido
    tiempo_compra_key   INTEGER       NOT NULL REFERENCES dim_tiempo (tiempo_key),
    tiempo_entrega_key  INTEGER                REFERENCES dim_tiempo (tiempo_key),  -- NULL: sin entrega
    cliente_key         INTEGER       NOT NULL REFERENCES dim_cliente (cliente_key),
    producto_key        INTEGER       NOT NULL REFERENCES dim_producto (producto_key),
    vendedor_key        INTEGER       NOT NULL REFERENCES dim_vendedor (vendedor_key),
    pago_key            INTEGER       NOT NULL REFERENCES dim_pago (pago_key),
    estado_key          INTEGER       NOT NULL REFERENCES dim_estado_pedido (estado_key),
    -- medidas
    precio              NUMERIC(10,2) NOT NULL CHECK (precio >= 0),
    flete               NUMERIC(10,2) NOT NULL CHECK (flete >= 0),
    total_item          NUMERIC(10,2) NOT NULL,           -- precio + flete
    cantidad            SMALLINT      NOT NULL DEFAULT 1,
    dias_entrega        INTEGER,                          -- entrega real - compra
    dias_retraso        INTEGER,                          -- entrega real - estimada
    entregado_tarde     BOOLEAN,                          -- NULL si no hay entrega
    review_score        SMALLINT      CHECK (review_score BETWEEN 1 AND 5),  -- puntaje del pedido
    PRIMARY KEY (order_id, order_item_id)
);

CREATE INDEX ix_fact_tiempo_compra  ON fact_ventas (tiempo_compra_key);
CREATE INDEX ix_fact_tiempo_entrega ON fact_ventas (tiempo_entrega_key);
CREATE INDEX ix_fact_cliente        ON fact_ventas (cliente_key);
CREATE INDEX ix_fact_producto       ON fact_ventas (producto_key);
CREATE INDEX ix_fact_vendedor       ON fact_ventas (vendedor_key);
CREATE INDEX ix_fact_pago           ON fact_ventas (pago_key);
CREATE INDEX ix_fact_estado         ON fact_ventas (estado_key);
