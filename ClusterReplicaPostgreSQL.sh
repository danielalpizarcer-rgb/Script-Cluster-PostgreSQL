#!/bin/bash
# Verificar si PostgreSQL está instalado
if command -v psql &> /dev/null; then
    VERSION_PG=$(psql --version | awk '{print $3}')
    echo "[OK] PostgreSQL ya está instalado (Versión: $VERSION_PG)."
else
    echo "[AVISO] PostgreSQL no está instalado. Procediendo con la instalación..."
    # Aquí puedes colocar tu código de instalación de dnf
fi

