# Guía: la web pública de ECLIPTA (GitHub Pages, para principiantes)

La carpeta `site/` es una web **estática** (solo HTML, CSS e imágenes, sin
servidor). GitHub la publica gratis con GitHub Pages cada vez que cambia algo en
`site/` en la rama `main` (workflow `.github/workflows/pages.yml`).

Páginas: portada en español (`index.html`) y en inglés (`en.html`), política de
privacidad (`privacidad.html` / `privacy.html`) y cómo borrar la cuenta
(`borrar-cuenta.html` / `delete-account.html`).

## Qué tienes que hacer tú (una sola vez)
1. En el repositorio: **Settings > Pages > Build and deployment > Source:
   GitHub Actions**.
2. **Settings > Secrets and variables > Actions > pestaña Variables > New
   repository variable**: nombre `NOMADIQ_SUPPORT_EMAIL`, valor tu correo de
   contacto (saldrá escrito en la web). Sin esta variable el workflow se para a
   propósito.
3. Fusiona el PR. El workflow publica solo (o lánzalo a mano en **Actions >
   pages > Run workflow**).
4. La dirección será `https://dp2005dario.github.io/NoMad-IQ/` (usuario y
   nombre del repositorio; si cambias el nombre del repo, cambia la dirección).

## Antes de enseñar la web a nadie, revisa
- La web dice que ECLIPTA **no está aún en Google Play**. Cuando se publique,
  cambia esa frase en `site/index.html` y `site/en.html`.
- Las imágenes son **maquetas** (diseños), no capturas de la app real; así lo
  dice la web. Cuando tengas capturas reales, ponlas en `site/img/`.
- La política de privacidad no nombra al proveedor de servidores ni la región
  porque aún no es definitivo. Cuando lo sea, añádelo en la sección 4 de
  `privacidad.html` y `privacy.html`.
- La política dice que quien responde es "un desarrollador independiente
  (España)": confirma que es correcto.
