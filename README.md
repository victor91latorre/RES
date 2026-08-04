# CONSIGNA · Punto de Venta + Matriz

Web app para **venta en consignación** de componentes electrónicos.
Dos portales (POS para el local y tablero para la matriz) + base **Supabase**.
Todo es **HTML/JS estático** → se despliega en **Vercel** en minutos.

Esta versión incluye **venta atómica a prueba de sobreventa**, **ticket_id** (agrupa
las líneas de una misma venta) y **escape de HTML** (anti-XSS) en ambos portales.

---

## 🗂️ Estructura

```
consigna-pos/
├── index.html                 → Landing (elige POS o Admin)
├── local.html                 → Punto de venta (carrito + venta atómica)
├── admin.html                 → Matriz (monitoreo, inventario, arqueo, sucursales)
├── config.js                  → URL + anon key de Supabase (edítalo aquí)
├── inventario_ejemplo.csv     → Plantilla para importar inventario
├── vercel.json                → Configuración de despliegue
├── .gitignore
├── README.md
└── sql/
    ├── setup.sql              → Instalación desde CERO (base nueva)
    └── migracion_atomica.sql  → Aplica venta atómica + ticket_id a una base EXISTENTE
```

---

## 1️⃣ Supabase (base de datos)

- **Base nueva:** SQL Editor → pega `sql/setup.sql` → **Run**.
- **Base existente (ya tienes datos):** SQL Editor → pega `sql/migracion_atomica.sql` → **Run**.
  (Solo agrega `ticket_id`, hace atómico el descuento y crea `fn_vender`. No borra datos.)

### Credenciales (`config.js`)
Ya vienen tu **URL** y **anon key**. La anon key es **pública** (va en el navegador): es seguro.
⚠️ **Nunca** pongas aquí la `service_role` key.

---

## 2️⃣ GitHub

```bash
git init
git add .
git commit -m "Consigna POS + Matriz (venta atomica)"
git branch -M main
git remote add origin https://github.com/TU_USUARIO/consigna-pos.git
git push -u origin main
```
Sin Git: en GitHub crea un repo y usa **Add file → Upload files**, arrastra todo y haz commit.

---

## 3️⃣ Vercel

1. <https://vercel.com> → inicia sesión con GitHub.
2. **Add New… → Project** → importa `consigna-pos`.
3. Framework Preset: **Other** (estático, sin build). Build Command y Output: **vacío**.
4. **Deploy**.

URLs resultantes: `/` (landing), `/local` (POS), `/admin` (matriz). Cada `git push` redespliega.

---

## ▶️ Primer arranque
1. **/admin** → 🏪 Sucursales → crea una (correo + contraseña).
2. 📦 Inventario → elige la sucursal → **Importar CSV** (`inventario_ejemplo.csv`).
3. **/local** → inicia sesión → arma el carrito → **Registrar venta**.
4. **/admin** → ventas, ganancia e inventario en tiempo real.

---

## 🔐 Seguridad — piloto vs producción
Modo piloto: contraseñas en texto plano y RLS permisivo (para probar rápido).
Antes de producción (ver notas al final de `sql/setup.sql`):
1. Login con **Supabase Auth** o hashing (`pgcrypto`).
2. Restringir `ventas` por `auth.uid()`.
3. Escritura de `productos`/`inventario` solo para rol admin.

---

## 📄 CSV
Encabezados exactos, sin comas dentro de los textos:
```
sku,nombre,precio,costo_reposicion,stock_inicial,stock_minimo
RP-001,Arduino uno,220,176,10,5
```
