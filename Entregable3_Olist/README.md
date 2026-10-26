# Entregable 3 · Mi primer dashboard (Olist)

Solución de Business Intelligence de extremo a extremo con **PostgreSQL, Python y Streamlit** sobre el dataset
*Brazilian E-Commerce Public Dataset by Olist* (Kaggle).

**Autor:** Dave Jairo Carvajal Gonzalez · UPSE · Facultad de Sistemas y Telecomunicaciones · Curso 6/1

**Dataset:** https://www.kaggle.com/olistbr/brazilian-ecommerce

## Qué hace

1. `etl/02_etl_cargar.py` lee los CSV, los limpia y carga un **esquema en estrella** en PostgreSQL
   (1 tabla de hechos y 6 dimensiones).
2. Las vistas y funciones SQL (`sql/04_vistas_funciones.sql`) calculan los KPI y las tablas del análisis.
3. `app/app.py` es un dashboard Streamlit que **solo consulta PostgreSQL**; no lee los CSV.

**Granularidad:** una fila de `fact_ventas` representa un ítem (producto) vendido dentro de un pedido.

## Estructura

```
Entregable3_Olist/
├── README.md
├── sql/
│   ├── 01_crear_tablas.sql        esquema dm, dimensiones y tabla de hechos
│   ├── 03_validaciones.sql        consultas de validación de la carga
│   └── 04_vistas_funciones.sql    6 vistas y 11 funciones para el dashboard
├── etl/
│   └── 02_etl_cargar.py           limpieza, transformación y carga
├── app/
│   ├── app.py                     aplicación Streamlit
│   └── requirements.txt
└── docs/                          documento final del proyecto y enlace del video
```

## Requisitos

- PostgreSQL 14 o superior (probado con PostgreSQL 18).
- Python 3.10 o superior (probado con Python 3.15).
- Los 9 archivos CSV del dataset, descargados de Kaggle y descomprimidos en una carpeta.

## Instalación y ejecución (Windows, PowerShell)

Reemplaza `CLAVE` por la contraseña de tu usuario `postgres`, y ajusta el puerto si no es 5432.
Si `psql` no está en el PATH, usa la ruta completa, por ejemplo
`& "C:\Program Files\PostgreSQL\18\bin\psql.exe"`.

**1. Instalar las librerías**

```
py -m pip install -r app\requirements.txt
```

**2. Crear la base de datos y las tablas**

```
psql -U postgres -p 5432 -c "CREATE DATABASE olist_dm;"
psql -U postgres -p 5432 -d olist_dm -f sql\01_crear_tablas.sql
```

**3. Cargar los datos**

```
$env:OLIST_DIR = "C:\data\olist"
$env:DB_URL = "postgresql+psycopg2://postgres:CLAVE@localhost:5432/olist_dm"
py etl\02_etl_cargar.py
```

Al final imprime el conteo de cada tabla. Debe verse `Ítems en CSV: 112,650 | filas en fact_ventas: 112,650`.

**4. Crear las vistas y funciones**

```
psql -U postgres -p 5432 -d olist_dm -f sql\04_vistas_funciones.sql
psql -U postgres -p 5432 -d olist_dm -c "ALTER DATABASE olist_dm SET search_path TO dm, public;"
```

El segundo comando es necesario: las funciones consultan la vista sin indicar el esquema, y sin él una conexión
nueva no la encuentra.

**5. Validar la carga**

```
psql -U postgres -p 5432 -d olist_dm -f sql\03_validaciones.sql
```

Todos los controles de integridad (huérfanos, duplicados y coherencia de medidas) deben dar `0`.

**6. Iniciar el dashboard**

```
cd app
py -m streamlit run app.py
```

Se abre en http://localhost:8501. La aplicación lee la conexión de la variable de entorno `DB_URL`
(la misma del paso 3), por lo que debe definirse en la misma ventana de PowerShell.

## Resultados de referencia (dataset completo)

| Tabla | Filas |
|---|---|
| dim_tiempo | 800 |
| dim_cliente | 96,096 |
| dim_producto | 32,951 |
| dim_vendedor | 3,095 |
| dim_pago | 11 |
| dim_estado_pedido | 8 |
| fact_ventas | 112,650 |

Totales: ingresos 13,591,643.70 y flete 2,251,909.54 (coinciden con la suma de `price` y `freight_value` del CSV).

## Contenido del dashboard

- **Ventas:** ingresos totales, ticket promedio, tasa de cancelación, ingresos por mes y top 10 de categorías.
- **Logística y satisfacción:** % de entregas tardías, tiempo promedio de entrega, satisfacción promedio,
  % de entregas tardías por estado, satisfacción según puntualidad y tabla de detalle de pedidos.
- **Filtros** (barra lateral): rango de fechas de compra, categoría de producto y estado del cliente (UF).
  Se envían como parámetros a las funciones SQL.

Regla de negocio: una *venta válida* excluye los pedidos `canceled` y `unavailable`.

## Solución de problemas

| Síntoma | Causa y solución |
|---|---|
| `UnicodeDecodeError: 'utf-8' codec can't decode byte 0xf3` al cargar | Casi siempre es contraseña incorrecta en `DB_URL`; PostgreSQL responde con un mensaje en español que psycopg2 no puede leer. Revisa usuario, contraseña y puerto. |
| `no existe la relación «vw_ventas_detalle»` | Se recrearon las tablas y se borraron las vistas, o falta el `search_path`. Ejecuta de nuevo el paso 4. |
| `Falta la variable de entorno DB_URL` en la app | Define `$env:DB_URL` en la misma ventana donde ejecutas Streamlit. |
| `python` no se reconoce | Usa `py` en lugar de `python`, o instala Python marcando *Add python.exe to PATH*. |
| Avisos `Pandas4Warning ... dayofweek` | Son advertencias y no afectan la carga. |
| Dos versiones de PostgreSQL instaladas | Cada una usa un puerto distinto (5432, 5433...). Indica el puerto correcto en `-p` y en `DB_URL`. |

## Notas del modelo

- La tabla de hechos se construye desde `order_items`; los pedidos sin ítems (775) no entran al modelo. Por eso
  hay 98,666 pedidos en el modelo frente a 99,441 en el CSV, y la tasa de cancelación se calcula sobre pedidos con ítems.
- `review_score` y `dias_entrega` se repiten en cada ítem de un pedido; las funciones los toman una vez por pedido.
- No se guardan contraseñas en el código: la conexión se lee de `DB_URL`.
