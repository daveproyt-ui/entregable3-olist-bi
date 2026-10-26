-- =====================================================================
-- Script 03: consultas de validación del Data Mart
-- Ejecutar DESPUÉS de cargar los datos (script 02)
-- =====================================================================
SET search_path TO dm, public;

-- 1) CANTIDAD DE REGISTROS CARGADOS ------------------------------------
SELECT 'dim_tiempo'        AS tabla, COUNT(*) AS registros FROM dim_tiempo
UNION ALL SELECT 'dim_cliente',       COUNT(*) FROM dim_cliente
UNION ALL SELECT 'dim_producto',      COUNT(*) FROM dim_producto
UNION ALL SELECT 'dim_vendedor',      COUNT(*) FROM dim_vendedor
UNION ALL SELECT 'dim_pago',          COUNT(*) FROM dim_pago
UNION ALL SELECT 'dim_estado_pedido', COUNT(*) FROM dim_estado_pedido
UNION ALL SELECT 'fact_ventas',       COUNT(*) FROM fact_ventas;

-- Pedidos distintos y rango de fechas cubierto
SELECT COUNT(DISTINCT order_id) AS pedidos,
       MIN(t.fecha)             AS primera_compra,
       MAX(t.fecha)             AS ultima_compra
FROM fact_ventas f
JOIN dim_tiempo t ON t.tiempo_key = f.tiempo_compra_key;

-- 2) INTEGRIDAD DE LAS RELACIONES (todas deben devolver 0) --------------
SELECT 'huérfanos tiempo_compra' AS control, COUNT(*) AS filas
FROM fact_ventas f LEFT JOIN dim_tiempo d ON d.tiempo_key = f.tiempo_compra_key WHERE d.tiempo_key IS NULL
UNION ALL
SELECT 'huérfanos tiempo_entrega', COUNT(*)
FROM fact_ventas f LEFT JOIN dim_tiempo d ON d.tiempo_key = f.tiempo_entrega_key
WHERE f.tiempo_entrega_key IS NOT NULL AND d.tiempo_key IS NULL
UNION ALL
SELECT 'huérfanos cliente', COUNT(*)
FROM fact_ventas f LEFT JOIN dim_cliente d ON d.cliente_key = f.cliente_key WHERE d.cliente_key IS NULL
UNION ALL
SELECT 'huérfanos producto', COUNT(*)
FROM fact_ventas f LEFT JOIN dim_producto d ON d.producto_key = f.producto_key WHERE d.producto_key IS NULL
UNION ALL
SELECT 'huérfanos vendedor', COUNT(*)
FROM fact_ventas f LEFT JOIN dim_vendedor d ON d.vendedor_key = f.vendedor_key WHERE d.vendedor_key IS NULL
UNION ALL
SELECT 'huérfanos pago', COUNT(*)
FROM fact_ventas f LEFT JOIN dim_pago d ON d.pago_key = f.pago_key WHERE d.pago_key IS NULL
UNION ALL
SELECT 'huérfanos estado', COUNT(*)
FROM fact_ventas f LEFT JOIN dim_estado_pedido d ON d.estado_key = f.estado_key WHERE d.estado_key IS NULL
UNION ALL
SELECT 'duplicados en la PK de la fact', COUNT(*) FROM (
    SELECT order_id, order_item_id FROM fact_ventas GROUP BY 1, 2 HAVING COUNT(*) > 1) x
UNION ALL
SELECT 'total_item <> precio + flete', COUNT(*) FROM fact_ventas WHERE total_item <> precio + flete
UNION ALL
SELECT 'entregado_tarde incoherente con dias_retraso', COUNT(*) FROM fact_ventas
WHERE entregado_tarde IS NOT NULL AND entregado_tarde <> (dias_retraso > 0);

-- 3) VALORES NULOS RELEVANTES -------------------------------------------
SELECT COUNT(*)                                           AS filas,
       COUNT(*) FILTER (WHERE tiempo_entrega_key IS NULL) AS sin_fecha_entrega,
       COUNT(*) FILTER (WHERE dias_entrega       IS NULL) AS sin_dias_entrega,
       COUNT(*) FILTER (WHERE entregado_tarde    IS NULL) AS sin_indicador_tardanza,
       COUNT(*) FILTER (WHERE review_score       IS NULL) AS sin_review
FROM fact_ventas;

-- Los nulos de entrega deben corresponder a pedidos NO entregados
SELECT e.order_status,
       COUNT(*)                                             AS items,
       COUNT(*) FILTER (WHERE f.tiempo_entrega_key IS NULL) AS sin_fecha_entrega
FROM fact_ventas f JOIN dim_estado_pedido e ON e.estado_key = f.estado_key
GROUP BY e.order_status ORDER BY items DESC;

-- Productos sin categoría original
SELECT COUNT(*) AS productos_sin_categoria FROM dim_producto WHERE categoria_pt = 'sin_categoria';

-- 4) TOTALES / MEDIDAS PRINCIPALES --------------------------------------
SELECT ROUND(SUM(precio), 2)                              AS ingresos_precio,
       ROUND(SUM(flete), 2)                               AS total_flete,
       ROUND(SUM(total_item), 2)                          AS total_con_flete,
       ROUND(SUM(precio) / COUNT(DISTINCT order_id), 2)   AS ticket_promedio,
       ROUND(AVG(precio), 2)                              AS precio_promedio_item
FROM fact_ventas;

SELECT e.order_status, COUNT(DISTINCT f.order_id) AS pedidos, ROUND(SUM(f.precio), 2) AS ingresos
FROM fact_ventas f JOIN dim_estado_pedido e ON e.estado_key = f.estado_key
GROUP BY e.order_status ORDER BY pedidos DESC;

SELECT t.anio_mes, COUNT(DISTINCT f.order_id) AS pedidos, ROUND(SUM(f.precio), 2) AS ingresos
FROM fact_ventas f JOIN dim_tiempo t ON t.tiempo_key = f.tiempo_compra_key
GROUP BY t.anio_mes ORDER BY t.anio_mes;
