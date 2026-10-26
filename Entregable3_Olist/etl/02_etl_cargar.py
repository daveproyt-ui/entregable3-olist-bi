"""
Entregable 2 · ETL del Data Mart Olist -> PostgreSQL
-----------------------------------------------------
Pasos: 1) leer CSV  2) limpiar/transformar  3) cargar dimensiones  4) construir y cargar la tabla de hechos.

Requisitos:  pip install pandas sqlalchemy psycopg2-binary
Uso:
    1. Descargar el dataset de Kaggle y descomprimirlo en una carpeta (por ejemplo ./data)
    2. Ejecutar antes 01_crear_tablas.sql en la base de datos
    3. Definir las variables (o editar los valores por defecto de abajo):
         OLIST_DIR  carpeta con los CSV
         DB_URL     postgresql+psycopg2://usuario:clave@localhost:5432/olist_dm
    4. python 02_etl_cargar.py
"""
import os
import unicodedata

import pandas as pd
from sqlalchemy import create_engine, text

DATA_DIR = os.getenv("OLIST_DIR", "./data")
DB_URL = os.getenv("DB_URL", "postgresql+psycopg2://postgres:postgres@localhost:5432/olist_dm")
SCHEMA = "dm"

engine = create_engine(DB_URL)


def leer(nombre, **kw):
    ruta = os.path.join(DATA_DIR, nombre)
    df = pd.read_csv(ruta, **kw)
    print(f"  {nombre:<48} {len(df):>9,} filas x {df.shape[1]} columnas")
    return df


def limpiar_texto(s):
    """minúsculas, sin acentos ni espacios sobrantes (unifica grafías de ciudades)."""
    if pd.isna(s):
        return None
    s = unicodedata.normalize("NFKD", str(s)).encode("ascii", "ignore").decode()
    return " ".join(s.lower().split()) or None


# ---------------------------------------------------------------------
# 1) EXTRACCIÓN
# ---------------------------------------------------------------------
print("1) Leyendo archivos CSV")
orders = leer("olist_orders_dataset.csv")
items = leer("olist_order_items_dataset.csv")
pays = leer("olist_order_payments_dataset.csv")
reviews = leer("olist_order_reviews_dataset.csv")
customers = leer("olist_customers_dataset.csv")
products = leer("olist_products_dataset.csv")
sellers = leer("olist_sellers_dataset.csv")
trans = leer("product_category_name_translation.csv")
# olist_geolocation_dataset.csv se descarta a propósito (ver documento: no aporta a los KPI)

# ---------------------------------------------------------------------
# 2) LIMPIEZA Y TRANSFORMACIÓN
# ---------------------------------------------------------------------
print("2) Limpiando y transformando")

# 2.1 Pedidos: fechas como datetime, sin duplicados
for c in ["order_purchase_timestamp", "order_approved_at", "order_delivered_carrier_date",
          "order_delivered_customer_date", "order_estimated_delivery_date"]:
    orders[c] = pd.to_datetime(orders[c], errors="coerce")
orders = orders.drop_duplicates("order_id")

# 2.2 Ítems: sin duplicados y con importes válidos
items = items.drop_duplicates(["order_id", "order_item_id"])
items["price"] = pd.to_numeric(items["price"], errors="coerce")
items["freight_value"] = pd.to_numeric(items["freight_value"], errors="coerce")
items = items[(items["price"] >= 0) & (items["freight_value"] >= 0)].dropna(subset=["price", "freight_value"])

# 2.3 Pagos: tipo principal (mayor valor), cuotas máximas y rango de cuotas por pedido
pays["payment_type"] = pays["payment_type"].replace({"not_defined": "no_definido"})
pays["payment_installments"] = pays["payment_installments"].clip(lower=1)
pays = pays.sort_values(["order_id", "payment_value"], ascending=[True, False])
pago_pedido = pays.drop_duplicates("order_id")[["order_id", "payment_type"]].rename(columns={"payment_type": "tipo_pago"})
pago_pedido = pago_pedido.merge(pays.groupby("order_id")["payment_installments"].max().rename("cuotas").reset_index(),
                                on="order_id")
pago_pedido["rango_cuotas"] = pd.cut(pago_pedido["cuotas"], bins=[0, 1, 6, 12, 1000],
                                     labels=["contado", "2-6 cuotas", "7-12 cuotas", "13+ cuotas"]).astype(str)

# 2.4 Reseñas: una por pedido (la más reciente); se descartan los comentarios de texto libre
reviews["review_answer_timestamp"] = pd.to_datetime(reviews["review_answer_timestamp"], errors="coerce")
reviews = (reviews.sort_values("review_answer_timestamp")
                  .drop_duplicates("order_id", keep="last")[["order_id", "review_score"]])

# 2.5 Productos: corregir columnas, categoría nula -> 'sin_categoria', traducir categoría
trans_dict = dict(zip(trans["product_category_name"], trans["product_category_name_english"]))
trans_dict.update({"pc_gamer": "pc_gamer",  # categorías que faltan en el archivo de traducción
                   "portateis_cozinha_e_preparadores_de_alimentos": "portable_kitchen_food_preparers"})
products = products.drop_duplicates("product_id")
products["categoria_pt"] = products["product_category_name"].fillna("sin_categoria")
products["categoria_en"] = products["categoria_pt"].map(trans_dict).fillna(products["categoria_pt"])
products["volumen_cm3"] = products["product_length_cm"] * products["product_height_cm"] * products["product_width_cm"]
dim_producto = products.rename(columns={"product_weight_g": "peso_g", "product_photos_qty": "num_fotos"})[
    ["product_id", "categoria_pt", "categoria_en", "peso_g", "volumen_cm3", "num_fotos"]]
dim_producto["peso_g"] = dim_producto["peso_g"].astype("Int64")
dim_producto["num_fotos"] = dim_producto["num_fotos"].astype("Int64")

# 2.6 Vendedores y clientes: ciudades normalizadas; un registro por cliente real
sellers["ciudad"] = sellers["seller_city"].map(limpiar_texto)
dim_vendedor = sellers.drop_duplicates("seller_id").rename(columns={"seller_state": "estado"})[["seller_id", "ciudad", "estado"]]

cust = customers.merge(orders[["customer_id", "order_purchase_timestamp"]], on="customer_id", how="left")
cust = cust.sort_values("order_purchase_timestamp").drop_duplicates("customer_unique_id", keep="last")
cust["ciudad"] = cust["customer_city"].map(limpiar_texto)
dim_cliente = cust.rename(columns={"customer_state": "estado"})[["customer_unique_id", "ciudad", "estado"]]

# 2.7 Dimensión de tiempo: calendario continuo que cubre todas las fechas usadas
fechas = pd.concat([orders["order_purchase_timestamp"], orders["order_delivered_customer_date"],
                    orders["order_estimated_delivery_date"]]).dropna()
cal = pd.DataFrame({"fecha": pd.date_range(fechas.min().normalize(), fechas.max().normalize(), freq="D")})
nombres_mes = ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto",
               "septiembre", "octubre", "noviembre", "diciembre"]
nombres_dia = ["lunes", "martes", "miercoles", "jueves", "viernes", "sabado", "domingo"]
dim_tiempo = pd.DataFrame({
    "tiempo_key": cal["fecha"].dt.strftime("%Y%m%d").astype(int),
    "fecha": cal["fecha"].dt.date,
    "anio": cal["fecha"].dt.year, "trimestre": cal["fecha"].dt.quarter, "mes": cal["fecha"].dt.month,
    "nombre_mes": cal["fecha"].dt.month.map(lambda m: nombres_mes[m - 1]),
    "anio_mes": cal["fecha"].dt.strftime("%Y-%m"), "dia": cal["fecha"].dt.day,
    "dia_semana": cal["fecha"].dt.dayofweek + 1,
    "nombre_dia_semana": cal["fecha"].dt.dayofweek.map(lambda d: nombres_dia[d]),
    "es_fin_de_semana": cal["fecha"].dt.dayofweek >= 5,
})

# 2.8 Dimensiones pequeñas
dim_pago = pago_pedido[["tipo_pago", "rango_cuotas"]].drop_duplicates()
dim_pago = pd.concat([dim_pago, pd.DataFrame([{"tipo_pago": "sin_pago", "rango_cuotas": "sin_pago"}])]).drop_duplicates()
dim_estado = pd.DataFrame({"order_status": orders["order_status"].dropna().unique()})
dim_estado["es_venta_valida"] = ~dim_estado["order_status"].isin(["canceled", "unavailable"])

# ---------------------------------------------------------------------
# 3) CARGA DE DIMENSIONES
# ---------------------------------------------------------------------
print("3) Cargando dimensiones en PostgreSQL")
with engine.begin() as con:
    con.execute(text(f"TRUNCATE {SCHEMA}.fact_ventas, {SCHEMA}.dim_tiempo, {SCHEMA}.dim_cliente, "
                     f"{SCHEMA}.dim_producto, {SCHEMA}.dim_vendedor, {SCHEMA}.dim_pago, "
                     f"{SCHEMA}.dim_estado_pedido RESTART IDENTITY CASCADE"))
for nombre, df in [("dim_tiempo", dim_tiempo), ("dim_cliente", dim_cliente), ("dim_producto", dim_producto),
                   ("dim_vendedor", dim_vendedor), ("dim_pago", dim_pago), ("dim_estado_pedido", dim_estado)]:
    df.to_sql(nombre, engine, schema=SCHEMA, if_exists="append", index=False, method="multi", chunksize=5000)
    print(f"  {nombre:<20} {len(df):>9,} filas")

# ---------------------------------------------------------------------
# 4) CONSTRUCCIÓN Y CARGA DE LA TABLA DE HECHOS
# ---------------------------------------------------------------------
print("4) Construyendo fact_ventas")
k_cli = pd.read_sql(f"SELECT cliente_key, customer_unique_id FROM {SCHEMA}.dim_cliente", engine)
k_pro = pd.read_sql(f"SELECT producto_key, product_id FROM {SCHEMA}.dim_producto", engine)
k_ven = pd.read_sql(f"SELECT vendedor_key, seller_id FROM {SCHEMA}.dim_vendedor", engine)
k_pag = pd.read_sql(f"SELECT pago_key, tipo_pago, rango_cuotas FROM {SCHEMA}.dim_pago", engine)
k_est = pd.read_sql(f"SELECT estado_key, order_status FROM {SCHEMA}.dim_estado_pedido", engine)

f = items.merge(orders, on="order_id", how="inner")
f = f.merge(customers[["customer_id", "customer_unique_id"]], on="customer_id", how="inner")
f = f.merge(pago_pedido[["order_id", "tipo_pago", "rango_cuotas"]], on="order_id", how="left")
f["tipo_pago"] = f["tipo_pago"].fillna("sin_pago")
f["rango_cuotas"] = f["rango_cuotas"].fillna("sin_pago")
f = f.merge(reviews, on="order_id", how="left")
for tabla, claves in [(k_cli, "customer_unique_id"), (k_pro, "product_id"), (k_ven, "seller_id"),
                      (k_est, "order_status"), (k_pag, ["tipo_pago", "rango_cuotas"])]:
    f = f.merge(tabla, on=claves, how="inner")   # 'inner' descarta cualquier fila sin dimensión

compra = f["order_purchase_timestamp"].dt.normalize()
entrega = f["order_delivered_customer_date"].dt.normalize()
estimada = f["order_estimated_delivery_date"].dt.normalize()
entrega_ok = entrega.where(entrega >= compra)          # una entrega anterior a la compra es un error -> NULL

hechos = pd.DataFrame({
    "order_id": f["order_id"],
    "order_item_id": f["order_item_id"].astype("int16"),
    "tiempo_compra_key": compra.dt.strftime("%Y%m%d").astype(int),
    "tiempo_entrega_key": entrega_ok.dt.strftime("%Y%m%d").astype("float").astype("Int64"),
    "cliente_key": f["cliente_key"], "producto_key": f["producto_key"], "vendedor_key": f["vendedor_key"],
    "pago_key": f["pago_key"], "estado_key": f["estado_key"],
    "precio": f["price"].round(2), "flete": f["freight_value"].round(2),
    "total_item": (f["price"] + f["freight_value"]).round(2),
    "cantidad": 1,
    "dias_entrega": (entrega_ok - compra).dt.days.astype("Int64"),
    "dias_retraso": (entrega_ok - estimada).dt.days.astype("Int64"),
    "review_score": f["review_score"].astype("Int64"),
})
hechos["entregado_tarde"] = (hechos["dias_retraso"] > 0).astype("boolean").where(hechos["dias_retraso"].notna())

hechos.to_sql("fact_ventas", engine, schema=SCHEMA, if_exists="append", index=False, method="multi", chunksize=5000)

# ---------------------------------------------------------------------
# 5) EVIDENCIA DE CARGA (copiar esta salida o una captura en el entregable)
# ---------------------------------------------------------------------
print("5) Conteo final por tabla")
with engine.connect() as con:
    for t in ["dim_tiempo", "dim_cliente", "dim_producto", "dim_vendedor", "dim_pago", "dim_estado_pedido", "fact_ventas"]:
        n = con.execute(text(f"SELECT COUNT(*) FROM {SCHEMA}.{t}")).scalar()
        print(f"  {t:<20} {n:>9,}")
print(f"  Ítems en CSV: {len(items):,}  |  filas en fact_ventas: {len(hechos):,}")
