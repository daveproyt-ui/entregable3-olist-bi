-- =====================================================================
-- Script 04: vistas y funciones SQL que alimentarán el dashboard
-- Regla de negocio: una "venta válida" excluye pedidos canceled / unavailable
-- Todos los parámetros de filtro son opcionales (NULL = sin filtro)
-- =====================================================================
SET search_path TO dm, public;

-- ---------------------------------------------------------------------
-- VISTA BASE: hecho + dimensiones desnormalizado (alimenta la tabla de detalle)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_ventas_detalle AS
SELECT f.order_id,
       f.order_item_id,
       tc.fecha                 AS fecha_compra,
       tc.anio_mes,
       tc.anio,
       te.fecha                 AS fecha_entrega,
       e.order_status,
       e.es_venta_valida,
       c.estado                 AS estado_cliente,
       c.ciudad                 AS ciudad_cliente,
       p.categoria_en           AS categoria,
       v.seller_id,
       v.estado                 AS estado_vendedor,
       pg.tipo_pago,
       pg.rango_cuotas,
       f.precio,
       f.flete,
       f.total_item,
       f.dias_entrega,
       f.dias_retraso,
       f.entregado_tarde,
       f.review_score
FROM fact_ventas f
JOIN dim_tiempo        tc ON tc.tiempo_key = f.tiempo_compra_key
LEFT JOIN dim_tiempo   te ON te.tiempo_key = f.tiempo_entrega_key
JOIN dim_cliente       c  ON c.cliente_key = f.cliente_key
JOIN dim_producto      p  ON p.producto_key = f.producto_key
JOIN dim_vendedor      v  ON v.vendedor_key = f.vendedor_key
JOIN dim_pago          pg ON pg.pago_key = f.pago_key
JOIN dim_estado_pedido e  ON e.estado_key = f.estado_key;

-- ---------------------------------------------------------------------
-- VISTA: KPI mensuales (gráfico de evolución)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_kpi_mensual AS
SELECT anio_mes,
       COUNT(DISTINCT order_id)                                        AS pedidos,
       ROUND(SUM(precio), 2)                                           AS ingresos,
       ROUND(SUM(precio) / NULLIF(COUNT(DISTINCT order_id), 0), 2)     AS ticket_promedio
FROM vw_ventas_detalle
WHERE es_venta_valida
GROUP BY anio_mes
ORDER BY anio_mes;

-- ---------------------------------------------------------------------
-- VISTA: ventas por categoría
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_ventas_categoria AS
SELECT categoria,
       COUNT(DISTINCT order_id)  AS pedidos,
       ROUND(SUM(precio), 2)     AS ingresos
FROM vw_ventas_detalle
WHERE es_venta_valida
GROUP BY categoria
ORDER BY ingresos DESC;

-- ---------------------------------------------------------------------
-- VISTA: logística por estado del cliente
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_logistica_estado AS
SELECT estado_cliente,
       COUNT(DISTINCT order_id) FILTER (WHERE entregado_tarde IS NOT NULL)  AS pedidos_entregados,
       COUNT(DISTINCT order_id) FILTER (WHERE entregado_tarde)              AS pedidos_tardios,
       ROUND(100.0 * COUNT(DISTINCT order_id) FILTER (WHERE entregado_tarde)
             / NULLIF(COUNT(DISTINCT order_id) FILTER (WHERE entregado_tarde IS NOT NULL), 0), 2) AS pct_tardios
FROM vw_ventas_detalle
WHERE es_venta_valida
GROUP BY estado_cliente
ORDER BY pct_tardios DESC NULLS LAST;

-- ---------------------------------------------------------------------
-- FUNCIONES ESCALARES (tarjetas de KPI)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_total_ingresos(
    p_ini DATE DEFAULT NULL, p_fin DATE DEFAULT NULL,
    p_categoria TEXT DEFAULT NULL, p_estado_cliente TEXT DEFAULT NULL)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(precio), 0)
    FROM vw_ventas_detalle
    WHERE es_venta_valida
      AND (p_ini IS NULL OR fecha_compra >= p_ini)
      AND (p_fin IS NULL OR fecha_compra <= p_fin)
      AND (p_categoria IS NULL OR categoria = p_categoria)
      AND (p_estado_cliente IS NULL OR estado_cliente = p_estado_cliente);
$$;

CREATE OR REPLACE FUNCTION fn_ticket_promedio(
    p_ini DATE DEFAULT NULL, p_fin DATE DEFAULT NULL,
    p_categoria TEXT DEFAULT NULL, p_estado_cliente TEXT DEFAULT NULL)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT ROUND(SUM(precio) / NULLIF(COUNT(DISTINCT order_id), 0), 2)
    FROM vw_ventas_detalle
    WHERE es_venta_valida
      AND (p_ini IS NULL OR fecha_compra >= p_ini)
      AND (p_fin IS NULL OR fecha_compra <= p_fin)
      AND (p_categoria IS NULL OR categoria = p_categoria)
      AND (p_estado_cliente IS NULL OR estado_cliente = p_estado_cliente);
$$;

-- % de pedidos entregados después de la fecha estimada
CREATE OR REPLACE FUNCTION fn_tasa_entregas_tardias(
    p_ini DATE DEFAULT NULL, p_fin DATE DEFAULT NULL,
    p_categoria TEXT DEFAULT NULL, p_estado_cliente TEXT DEFAULT NULL)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT ROUND(100.0 * COUNT(DISTINCT order_id) FILTER (WHERE entregado_tarde)
                 / NULLIF(COUNT(DISTINCT order_id) FILTER (WHERE entregado_tarde IS NOT NULL), 0), 2)
    FROM vw_ventas_detalle
    WHERE es_venta_valida
      AND (p_ini IS NULL OR fecha_compra >= p_ini)
      AND (p_fin IS NULL OR fecha_compra <= p_fin)
      AND (p_categoria IS NULL OR categoria = p_categoria)
      AND (p_estado_cliente IS NULL OR estado_cliente = p_estado_cliente);
$$;

-- Días promedio de entrega (un valor por pedido, para no pesar por n.º de ítems)
CREATE OR REPLACE FUNCTION fn_tiempo_promedio_entrega(
    p_ini DATE DEFAULT NULL, p_fin DATE DEFAULT NULL,
    p_categoria TEXT DEFAULT NULL, p_estado_cliente TEXT DEFAULT NULL)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT ROUND(AVG(d), 2) FROM (
        SELECT order_id, MAX(dias_entrega) AS d
        FROM vw_ventas_detalle
        WHERE es_venta_valida AND dias_entrega IS NOT NULL
          AND (p_ini IS NULL OR fecha_compra >= p_ini)
          AND (p_fin IS NULL OR fecha_compra <= p_fin)
          AND (p_categoria IS NULL OR categoria = p_categoria)
          AND (p_estado_cliente IS NULL OR estado_cliente = p_estado_cliente)
        GROUP BY order_id) x;
$$;

-- Puntaje promedio (un valor por pedido, porque review_score se repite en cada ítem)
CREATE OR REPLACE FUNCTION fn_satisfaccion_promedio(
    p_ini DATE DEFAULT NULL, p_fin DATE DEFAULT NULL,
    p_categoria TEXT DEFAULT NULL, p_estado_cliente TEXT DEFAULT NULL)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT ROUND(AVG(s), 2) FROM (
        SELECT order_id, MAX(review_score) AS s
        FROM vw_ventas_detalle
        WHERE es_venta_valida AND review_score IS NOT NULL
          AND (p_ini IS NULL OR fecha_compra >= p_ini)
          AND (p_fin IS NULL OR fecha_compra <= p_fin)
          AND (p_categoria IS NULL OR categoria = p_categoria)
          AND (p_estado_cliente IS NULL OR estado_cliente = p_estado_cliente)
        GROUP BY order_id) x;
$$;

-- % de pedidos cancelados sobre el total (no aplica el filtro de venta válida)
CREATE OR REPLACE FUNCTION fn_tasa_cancelacion(
    p_ini DATE DEFAULT NULL, p_fin DATE DEFAULT NULL,
    p_categoria TEXT DEFAULT NULL, p_estado_cliente TEXT DEFAULT NULL)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT ROUND(100.0 * COUNT(DISTINCT order_id) FILTER (WHERE order_status = 'canceled')
                 / NULLIF(COUNT(DISTINCT order_id), 0), 2)
    FROM vw_ventas_detalle
    WHERE (p_ini IS NULL OR fecha_compra >= p_ini)
      AND (p_fin IS NULL OR fecha_compra <= p_fin)
      AND (p_categoria IS NULL OR categoria = p_categoria)
      AND (p_estado_cliente IS NULL OR estado_cliente = p_estado_cliente);
$$;

-- ---------------------------------------------------------------------
-- FUNCIONES DE TABLA (gráficos y tabla de detalle)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_ventas_por_mes(
    p_ini DATE DEFAULT NULL, p_fin DATE DEFAULT NULL,
    p_categoria TEXT DEFAULT NULL, p_estado_cliente TEXT DEFAULT NULL)
RETURNS TABLE (anio_mes TEXT, pedidos BIGINT, ingresos NUMERIC)
LANGUAGE sql STABLE AS $$
    SELECT v.anio_mes::TEXT, COUNT(DISTINCT v.order_id), ROUND(SUM(v.precio), 2)
    FROM vw_ventas_detalle v
    WHERE v.es_venta_valida
      AND (p_ini IS NULL OR v.fecha_compra >= p_ini)
      AND (p_fin IS NULL OR v.fecha_compra <= p_fin)
      AND (p_categoria IS NULL OR v.categoria = p_categoria)
      AND (p_estado_cliente IS NULL OR v.estado_cliente = p_estado_cliente)
    GROUP BY v.anio_mes
    ORDER BY v.anio_mes;
$$;

CREATE OR REPLACE FUNCTION fn_top_categorias(
    p_ini DATE DEFAULT NULL, p_fin DATE DEFAULT NULL,
    p_estado_cliente TEXT DEFAULT NULL, p_top INTEGER DEFAULT 10)
RETURNS TABLE (categoria TEXT, pedidos BIGINT, ingresos NUMERIC)
LANGUAGE sql STABLE AS $$
    SELECT v.categoria::TEXT, COUNT(DISTINCT v.order_id), ROUND(SUM(v.precio), 2)
    FROM vw_ventas_detalle v
    WHERE v.es_venta_valida
      AND (p_ini IS NULL OR v.fecha_compra >= p_ini)
      AND (p_fin IS NULL OR v.fecha_compra <= p_fin)
      AND (p_estado_cliente IS NULL OR v.estado_cliente = p_estado_cliente)
    GROUP BY v.categoria
    ORDER BY SUM(v.precio) DESC
    LIMIT p_top;
$$;

CREATE OR REPLACE FUNCTION fn_tardias_por_estado(
    p_ini DATE DEFAULT NULL, p_fin DATE DEFAULT NULL, p_categoria TEXT DEFAULT NULL)
RETURNS TABLE (estado_cliente TEXT, pedidos_entregados BIGINT, pct_tardios NUMERIC)
LANGUAGE sql STABLE AS $$
    SELECT v.estado_cliente::TEXT,
           COUNT(DISTINCT v.order_id) FILTER (WHERE v.entregado_tarde IS NOT NULL),
           ROUND(100.0 * COUNT(DISTINCT v.order_id) FILTER (WHERE v.entregado_tarde)
                 / NULLIF(COUNT(DISTINCT v.order_id) FILTER (WHERE v.entregado_tarde IS NOT NULL), 0), 2)
    FROM vw_ventas_detalle v
    WHERE v.es_venta_valida
      AND (p_ini IS NULL OR v.fecha_compra >= p_ini)
      AND (p_fin IS NULL OR v.fecha_compra <= p_fin)
      AND (p_categoria IS NULL OR v.categoria = p_categoria)
    GROUP BY v.estado_cliente
    ORDER BY 3 DESC NULLS LAST;
$$;

-- Satisfacción según puntualidad (responde la pregunta 3 del Entregable 1)
CREATE OR REPLACE FUNCTION fn_satisfaccion_vs_retraso(
    p_ini DATE DEFAULT NULL, p_fin DATE DEFAULT NULL,
    p_categoria TEXT DEFAULT NULL, p_estado_cliente TEXT DEFAULT NULL)
RETURNS TABLE (puntualidad TEXT, pedidos BIGINT, puntaje_promedio NUMERIC)
LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN x.tarde THEN 'Entrega tardía' ELSE 'A tiempo' END,
           COUNT(*), ROUND(AVG(x.s), 2)
    FROM (
        SELECT v.order_id, BOOL_OR(v.entregado_tarde) AS tarde, MAX(v.review_score) AS s
        FROM vw_ventas_detalle v
        WHERE v.es_venta_valida AND v.entregado_tarde IS NOT NULL AND v.review_score IS NOT NULL
          AND (p_ini IS NULL OR v.fecha_compra >= p_ini)
          AND (p_fin IS NULL OR v.fecha_compra <= p_fin)
          AND (p_categoria IS NULL OR v.categoria = p_categoria)
          AND (p_estado_cliente IS NULL OR v.estado_cliente = p_estado_cliente)
        GROUP BY v.order_id) x
    GROUP BY x.tarde
    ORDER BY x.tarde;
$$;

-- Tabla de detalle (últimos pedidos que cumplen los filtros)
CREATE OR REPLACE FUNCTION fn_detalle_pedidos(
    p_ini DATE DEFAULT NULL, p_fin DATE DEFAULT NULL,
    p_categoria TEXT DEFAULT NULL, p_estado_cliente TEXT DEFAULT NULL,
    p_limite INTEGER DEFAULT 100)
RETURNS TABLE (order_id TEXT, fecha_compra DATE, categoria TEXT, estado_cliente TEXT,
               order_status TEXT, precio NUMERIC, flete NUMERIC, dias_entrega INTEGER,
               entregado_tarde BOOLEAN, review_score SMALLINT)
LANGUAGE sql STABLE AS $$
    SELECT v.order_id::TEXT, v.fecha_compra, v.categoria::TEXT, v.estado_cliente::TEXT,
           v.order_status::TEXT, v.precio, v.flete, v.dias_entrega, v.entregado_tarde, v.review_score
    FROM vw_ventas_detalle v
    WHERE (p_ini IS NULL OR v.fecha_compra >= p_ini)
      AND (p_fin IS NULL OR v.fecha_compra <= p_fin)
      AND (p_categoria IS NULL OR v.categoria = p_categoria)
      AND (p_estado_cliente IS NULL OR v.estado_cliente = p_estado_cliente)
    ORDER BY v.fecha_compra DESC, v.order_id
    LIMIT p_limite;
$$;

-- Listas para llenar los filtros del dashboard
CREATE OR REPLACE VIEW vw_filtro_categorias AS
SELECT DISTINCT categoria FROM vw_ventas_detalle ORDER BY categoria;

CREATE OR REPLACE VIEW vw_filtro_estados_cliente AS
SELECT DISTINCT estado_cliente FROM vw_ventas_detalle WHERE estado_cliente IS NOT NULL ORDER BY estado_cliente;
