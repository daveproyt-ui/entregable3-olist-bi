"""
Entregable 3 · Dashboard BI Olist (Streamlit + PostgreSQL)

Todos los datos se leen de PostgreSQL (esquema dm) mediante las vistas y
funciones del script 04_vistas_funciones.sql. La aplicación NO lee los CSV.

Ejecución:
    $env:DB_URL = "postgresql+psycopg2://postgres:CLAVE@localhost:5432/olist_dm"
    py -m streamlit run app.py
"""
import os
from datetime import date

import pandas as pd
import plotly.express as px
import streamlit as st
from sqlalchemy import create_engine, text

st.set_page_config(page_title="Olist · Dashboard BI", page_icon="📦", layout="wide")

COLOR = "#1f6f8b"        # color principal de los gráficos
COLOR_ALERTA = "#c0392b"  # entregas tardías / valores a vigilar
TODAS = "Todas"


# ---------------------------------------------------------------------------
# Conexión a PostgreSQL
# ---------------------------------------------------------------------------
@st.cache_resource
def get_engine():
    url = os.getenv("DB_URL")
    if not url:
        st.error(
            "Falta la variable de entorno DB_URL. En PowerShell:\n\n"
            '$env:DB_URL = "postgresql+psycopg2://postgres:CLAVE@localhost:5432/olist_dm"'
        )
        st.stop()
    return create_engine(url, pool_pre_ping=True)


@st.cache_data(ttl=600, show_spinner=False)
def consultar(sql: str, params: tuple = ()) -> pd.DataFrame:
    """Ejecuta una consulta parametrizada y devuelve un DataFrame."""
    p = dict(params)
    with get_engine().connect() as con:
        df = pd.read_sql(text(sql), con, params=p)
    return df


def escalar(sql: str, params: tuple = ()):
    df = consultar(sql, params)
    v = df.iloc[0, 0]
    return None if pd.isna(v) else float(v)


# ---------------------------------------------------------------------------
# Filtros globales (barra lateral)
# ---------------------------------------------------------------------------
try:
    rango = consultar(
        "SELECT MIN(fecha_compra) AS fmin, MAX(fecha_compra) AS fmax FROM dm.vw_ventas_detalle"
    )
    categorias = consultar("SELECT categoria FROM dm.vw_filtro_categorias")["categoria"].tolist()
    estados = consultar("SELECT estado_cliente FROM dm.vw_filtro_estados_cliente")["estado_cliente"].tolist()
except Exception as e:  # conexión o vistas inexistentes
    st.error(f"No se pudo consultar PostgreSQL: {e}")
    st.stop()

fmin, fmax = rango.loc[0, "fmin"], rango.loc[0, "fmax"]
# Rango por defecto: meses completos (ene-2017 a ago-2018), ajustado a los datos
def_ini = max(fmin, date(2017, 1, 1))
def_fin = min(fmax, date(2018, 8, 31))

st.sidebar.title("📦 Olist BI")
pagina = st.sidebar.radio("Sección", ["Ventas", "Logística y satisfacción"])
st.sidebar.header("Filtros")
fechas = st.sidebar.date_input(
    "Rango de fechas de compra",
    value=(def_ini, def_fin), min_value=fmin, max_value=fmax,
)
if not (isinstance(fechas, (tuple, list)) and len(fechas) == 2):
    st.sidebar.info("Selecciona fecha inicial y final.")
    st.stop()
f_ini, f_fin = fechas
cat_sel = st.sidebar.selectbox("Categoría de producto", [TODAS] + categorias)
uf_sel = st.sidebar.selectbox("Estado del cliente (UF)", [TODAS] + estados)

categoria = None if cat_sel == TODAS else cat_sel
uf = None if uf_sel == TODAS else uf_sel
P = (("ini", f_ini), ("fin", f_fin), ("cat", categoria), ("uf", uf))

st.sidebar.caption(
    "Los filtros se envían como parámetros a las funciones SQL del esquema dm. "
    "Una venta válida excluye pedidos cancelados y no disponibles."
)

ARGS4 = "CAST(:ini AS date), CAST(:fin AS date), CAST(:cat AS text), CAST(:uf AS text)"


def kpi(col, titulo, valor, fmt, ayuda):
    col.metric(titulo, "—" if valor is None else fmt.format(valor), help=ayuda)


def sin_datos(df) -> bool:
    if df.empty:
        st.info("No hay datos para la combinación de filtros seleccionada.")
        return True
    return False


# ---------------------------------------------------------------------------
# SECCIÓN 1 · VENTAS  (P1)
# ---------------------------------------------------------------------------
if pagina == "Ventas":
    st.title("Ventas")
    st.caption("P1 · ¿Cómo evolucionan las ventas y qué categorías generan más ingresos?")

    c1, c2, c3 = st.columns(3)
    kpi(c1, "Ingresos totales", escalar(f"SELECT dm.fn_total_ingresos({ARGS4})", P),
        "R$ {:,.0f}", "Suma de precio en ventas válidas. fn_total_ingresos()")
    kpi(c2, "Ticket promedio", escalar(f"SELECT dm.fn_ticket_promedio({ARGS4})", P),
        "R$ {:,.2f}", "Ingresos ÷ pedidos distintos. fn_ticket_promedio()")
    kpi(c3, "Tasa de cancelación", escalar(f"SELECT dm.fn_tasa_cancelacion({ARGS4})", P),
        "{:.2f} %", "Pedidos cancelados ÷ total de pedidos con ítems. fn_tasa_cancelacion()")

    g1, g2 = st.columns(2)
    with g1:
        st.subheader("Evolución mensual de ingresos")
        mes = consultar(f"SELECT * FROM dm.fn_ventas_por_mes({ARGS4})", P)
        if not sin_datos(mes):
            fig = px.line(mes, x="anio_mes", y="ingresos", markers=True,
                          labels={"anio_mes": "Mes", "ingresos": "Ingresos (R$)"})
            fig.update_traces(line_color=COLOR)
            fig.update_layout(margin=dict(t=10, b=10), xaxis_tickangle=-45)
            st.plotly_chart(fig, width="stretch")
            with st.expander("Pedidos por mes"):
                st.dataframe(mes, width="stretch", hide_index=True)
    with g2:
        st.subheader("Top 10 categorías por ingresos")
        top = consultar(
            "SELECT * FROM dm.fn_top_categorias("
            "CAST(:ini AS date), CAST(:fin AS date), CAST(:uf AS text), 10)",
            (("ini", f_ini), ("fin", f_fin), ("uf", uf)),
        )
        if not sin_datos(top):
            fig = px.bar(top.sort_values("ingresos"), x="ingresos", y="categoria",
                         orientation="h", labels={"ingresos": "Ingresos (R$)", "categoria": ""})
            fig.update_traces(marker_color=COLOR)
            fig.update_layout(margin=dict(t=10, b=10))
            st.plotly_chart(fig, width="stretch")
            if categoria:
                st.caption("Este gráfico compara categorías, por eso no aplica el filtro de categoría.")

    with st.expander("Consultas SQL de esta sección"):
        st.code(
            "SELECT dm.fn_total_ingresos(ini, fin, categoria, uf);\n"
            "SELECT dm.fn_ticket_promedio(ini, fin, categoria, uf);\n"
            "SELECT dm.fn_tasa_cancelacion(ini, fin, categoria, uf);\n"
            "SELECT * FROM dm.fn_ventas_por_mes(ini, fin, categoria, uf);\n"
            "SELECT * FROM dm.fn_top_categorias(ini, fin, uf, 10);",
            language="sql",
        )

# ---------------------------------------------------------------------------
# SECCIÓN 2 · LOGÍSTICA Y SATISFACCIÓN  (P2 y P3)
# ---------------------------------------------------------------------------
else:
    st.title("Logística y satisfacción")
    st.caption("P2 · ¿Qué tan eficiente es la entrega?   P3 · ¿El retraso afecta la satisfacción?")

    c1, c2, c3 = st.columns(3)
    kpi(c1, "Entregas tardías", escalar(f"SELECT dm.fn_tasa_entregas_tardias({ARGS4})", P),
        "{:.2f} %", "Pedidos entregados después de la fecha estimada ÷ pedidos entregados.")
    kpi(c2, "Tiempo promedio de entrega", escalar(f"SELECT dm.fn_tiempo_promedio_entrega({ARGS4})", P),
        "{:.1f} días", "Días entre compra y entrega, un valor por pedido.")
    kpi(c3, "Satisfacción promedio", escalar(f"SELECT dm.fn_satisfaccion_promedio({ARGS4})", P),
        "{:.2f} / 5", "Puntaje de reseña (1 a 5), un valor por pedido.")

    g1, g2 = st.columns(2)
    with g1:
        st.subheader("% de entregas tardías por estado")
        tard = consultar(
            "SELECT * FROM dm.fn_tardias_por_estado("
            "CAST(:ini AS date), CAST(:fin AS date), CAST(:cat AS text))",
            (("ini", f_ini), ("fin", f_fin), ("cat", categoria)),
        )
        if not sin_datos(tard):
            top_n = tard.head(15).sort_values("pct_tardios")
            fig = px.bar(top_n, x="pct_tardios", y="estado_cliente", orientation="h",
                         hover_data=["pedidos_entregados"],
                         labels={"pct_tardios": "% tardías", "estado_cliente": "UF"})
            fig.update_traces(marker_color=COLOR_ALERTA)
            fig.update_layout(margin=dict(t=10, b=10))
            st.plotly_chart(fig, width="stretch")
            st.caption("Se muestran los 15 estados con mayor porcentaje. "
                       "Este gráfico compara estados, por eso no aplica el filtro de estado.")
    with g2:
        st.subheader("Satisfacción según puntualidad")
        sat = consultar(f"SELECT * FROM dm.fn_satisfaccion_vs_retraso({ARGS4})", P)
        if not sin_datos(sat):
            fig = px.bar(sat, x="puntualidad", y="puntaje_promedio", text="puntaje_promedio",
                         hover_data=["pedidos"],
                         labels={"puntualidad": "", "puntaje_promedio": "Puntaje promedio (1-5)"})
            fig.update_traces(marker_color=COLOR, textposition="outside")
            fig.update_yaxes(range=[0, 5])
            fig.update_layout(margin=dict(t=10, b=10))
            st.plotly_chart(fig, width="stretch")

    st.subheader("Detalle de pedidos")
    limite = st.slider("Cantidad de filas a mostrar", 10, 500, 100, step=10)
    det = consultar(
        "SELECT * FROM dm.fn_detalle_pedidos("
        "CAST(:ini AS date), CAST(:fin AS date), CAST(:cat AS text), CAST(:uf AS text), :lim)",
        P + (("lim", limite),),
    )
    if not sin_datos(det):
        st.dataframe(det, width="stretch", hide_index=True)
        st.download_button("Descargar CSV", det.to_csv(index=False).encode("utf-8"),
                           "detalle_pedidos.csv", "text/csv")

    with st.expander("Consultas SQL de esta sección"):
        st.code(
            "SELECT dm.fn_tasa_entregas_tardias(ini, fin, categoria, uf);\n"
            "SELECT dm.fn_tiempo_promedio_entrega(ini, fin, categoria, uf);\n"
            "SELECT dm.fn_satisfaccion_promedio(ini, fin, categoria, uf);\n"
            "SELECT * FROM dm.fn_tardias_por_estado(ini, fin, categoria);\n"
            "SELECT * FROM dm.fn_satisfaccion_vs_retraso(ini, fin, categoria, uf);\n"
            "SELECT * FROM dm.fn_detalle_pedidos(ini, fin, categoria, uf, limite);",
            language="sql",
        )
