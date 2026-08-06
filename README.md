# RESI-STORE · POS + Matriz

Web app para **venta en consignación** de componentes electrónicos.
Dos portales (POS para el local y tablero para la matriz) + base **Supabase**.
Todo es **HTML/JS estático** → se despliega en **Vercel** en minutos.

Incluye: carrito multi-producto, **venta atómica a prueba de sobreventa**, ticket
digital con logo y publicidad, **localizador 3D de gavetas** (444 del mueble real),
cortes quincenales, arqueo y alarmas de stock.

---

## 🗂️ Estructura

```
resi-pos/
├── index.html                 → Landing (elige POS o Admin)
├── local.html                 → Punto de venta (carrito + 3D localizador)
├── admin.html                 → Matriz (monitoreo, inventario CSV con gavetas, arqueo)
├── config.js                  → URL + anon key de Supabase (edítalo aquí)
├── logo.png                   → Logo Resi-Store (fondo transparente)
├── inventario_444_gavetas.csv → Inventario real (422 productos) + gavetas
├── vercel.json  ·  .gitignore  ·  README.md
└── sql/
    ├── setup.sql              → Instalación desde CERO (tablas + 444 gavetas + todo)
    └── migracion_gavetas_3d.sql → Agrega gavetas a una base EXISTENTE
```

---

## 1️⃣ Supabase (base de datos)

- **Base NUEVA:** SQL Editor → pega `sql/setup.sql` → **Run**. (Crea todo, incluidas las 444 gavetas.)
- **Base que YA tienes (con datos):** si aún no tienes gavetas, corre `sql/migracion_gavetas_3d.sql`.

Verifica:
```sql
select count(*) from public.gavetas;   -- debe dar 444
```

### Credenciales (`config.js`)
Ya vienen tu URL y anon key. La anon key es **pública** (va en el navegador): es seguro.
⚠️ **Nunca** pongas aquí la `service_role` key.

---

## 2️⃣ GitHub

```bash
git init
git add .
git commit -m "Resi-Store POS + Matriz"
git branch -M main
git remote add origin https://github.com/TU_USUARIO/resi-pos.git
git push -u origin main
```
Sin Git: en GitHub crea un repo → **Add file → Upload files** → arrastra TODO → commit.

---

## 3️⃣ Vercel

1. <https://vercel.com> → inicia sesión con GitHub.
2. **Add New… → Project** → importa `resi-pos`.
3. Framework Preset: **Other** · Build Command y Output: **vacío**.
4. **Deploy**.

URLs: `/` (landing), `/local` (POS), `/admin` (matriz). Cada `git push` redespliega.

---

## ▶️ Primer arranque

1. **/admin** → 🏪 Sucursales → crea una (correo + contraseña) → te da el ID (ej. PDV-001).
2. 📦 Inventario → elige la sucursal → **Importar CSV** (`inventario_444_gavetas.csv`).
   Debe decir *"✔ Importados 422 productos · 422 con gaveta asignada"*.
3. **/local** → inicia sesión con el correo/contraseña → arma el carrito → **Registrar venta**.
4. Al confirmar, aparece el **localizador 3D**: recorre las gavetas y toca **✔ Surtido**;
   al terminar → **Ver ticket** (con logo + publicidad para foto).

---

## 📄 Formato del CSV
Encabezados exactos, sin comas dentro de los textos. La columna `gaveta` conecta el
producto con su cajón físico (debe existir en la tabla `gavetas`).
```
sku,nombre,precio,costo_reposicion,stock_inicial,stock_minimo,gaveta
SKU-0001,Diodo 1N4001,3,3,50,5,C1-S1-R1-P1
```

---

## 🔐 Seguridad — piloto vs producción
Modo piloto: contraseñas en texto plano y RLS permisivo (para probar rápido).
Antes de producción (ver notas al final de `sql/setup.sql`):
1. Login con **Supabase Auth** o hashing (`pgcrypto`).
2. Restringir `ventas` por `auth.uid()`.
3. Escritura de `productos`/`inventario` solo para rol admin.

---

## 📞 Contacto Resi-Store
Impresión 3D y fabricación de placas PCB · **443 502 5665**
Lic. Mariano De Jesús Torres 343, Dr. Miguel Silva González, 58110 Morelia, Mich.
