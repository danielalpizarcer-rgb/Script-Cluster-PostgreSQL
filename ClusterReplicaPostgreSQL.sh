#!/bin/bash
set -e

# Asegurar que corra como root
if [ "$EUID" -ne 0 ]; then
  echo "Por favor, ejecuta este script como root o usando sudo."
  exit 1
 Dil

# Instalar sshpass si no existe (necesario para automatizar comandos remotos con contraseña)
if ! command -v sshpass &> /dev/null; then
    echo "Instalando sshpass para la gestión remota..."
    dnf install -y sshpass
fi

# =====================================================================
# INTERFAZ INTERACTIVA (PREGUNTAS)
# =====================================================================
echo "============================================================"
echo " CONFIGURADOR CENTRALIZADO DE REPLICACIÓN POSTGRESQL + REPMGR "
echo "============================================================"
echo ""

read -p "Ingresa la IP de ESTE servidor (Nodo Primario): " IP_PRIMARY
read -p "Ingresa la contraseña del usuario 'root' de Linux para este servidor: " PASS_ROOT_PRIMARY
read -p "Define la contraseña para el usuario de sistema 'postgres' y REPMGR: " PASS_REPMGR

echo ""
read -p "¿Cuántos nodos SECUNDARIOS (Standby) deseas configurar?: " NUM_STANDBYS

# Arrays para guardar datos de los secundarios
declare -A STANDBY_IPS
declare -A STANDBY_ROOT_PASS

for ((i=1; i<=$NUM_STANDBYS; i++)); do
    echo ""
    read -p "Ingresa la IP del Nodo Standby #$i: " ip_temp
    read -p "Ingresa la contraseña 'root' de Linux para el Standby #$i: " pass_temp
    STANDBY_IPS[$i]=$ip_temp
    STANDBY_ROOT_PASS[$i]=$pass_temp
done

DATA_DIR="/var/lib/pgsql/15/data"

# =====================================================================
# PASOS COMUNES EN EL PRIMARIO (LOCAL)
# =====================================================================
echo -e "\n[LOCAL] Configurando Nodo Primario..."

systemctl stop firewalld || true
systemctl disable firewalld || true

dnf install -y https://postgresql.org
dnf install -y nano postgresql15 postgresql15-server postgresql15-contrib repmgr_15

echo "postgres:$PASS_REPMGR" | chpasswd

# Crear .pgpass local
PGPASS_FILE="/var/lib/pgsql/.pgpass"
cat <<EOF > $PGPASS_FILE
$IP_PRIMARY:5432:repmgr:repmgr:$PASS_REPMGR
$IP_PRIMARY:5432:postgres:postgres:$PASS_REPMGR
EOF
for i in "${!STANDBY_IPS[@]}"; do
    echo "${STANDBY_IPS[$i]}:5432:repmgr:repmgr:$PASS_REPMGR" >> $PGPASS_FILE
    echo "${STANDBY_IPS[$i]}:5432:postgres:postgres:$PASS_REPMGR" >> $PGPASS_FILE
done
chown postgres:postgres $PGPASS_FILE
chmod 600 $PGPASS_FILE

if [ ! -f "$DATA_DIR/PG_VERSION" ]; then
    sudo -u postgres /usr/pgsql-15/bin/initdb -D $DATA_DIR
fi

mkdir -p /var/lib/pgsql/15/archive/
chown -R postgres:postgres /var/lib/pgsql/15/archive/

cat <<EOF >> $DATA_DIR/postgresql.conf
listen_addresses = '*'
wal_level = replica
max_wal_senders = 10
hot_standby = on
archive_mode = on
archive_command = 'cp %p /var/lib/pgsql/15/archive/%f'
EOF

cat <<EOF >> $DATA_DIR/pg_hba.conf
host    replication     repmgr          $IP_PRIMARY/32        md5
host    repmgr          repmgr          $IP_PRIMARY/32        md5
EOF
for i in "${!STANDBY_IPS[@]}"; do
    echo "host    replication     repmgr          ${STANDBY_IPS[$i]}/32        md5" >> $DATA_DIR/pg_hba.conf
    echo "host    repmgr          repmgr          ${STANDBY_IPS[$i]}/32        md5" >> $DATA_DIR/pg_hba.conf
done

systemctl daemon-reload
systemctl enable postgresql-15
systemctl start postgresql-15

sudo -u postgres psql -c "CREATE ROLE repmgr WITH LOGIN SUPERUSER PASSWORD '$PASS_REPMGR';"
sudo -u postgres psql -c "CREATE DATABASE repmgr OWNER repmgr;"
sudo -u postgres psql -d repmgr -c "CREATE EXTENSION repmgr;"

cat <<EOF > /etc/repmgr/15/repmgr.conf
node_id=1
node_name='nodo1'
conninfo='host=$IP_PRIMARY user=repmgr dbname=repmgr password=$PASS_REPMGR connect_timeout=2'
data_directory='$DATA_DIR'
use_replication_slots=yes
log_file='/var/log/repmgr/repmgr-primary.log'
priority=100
EOF
chown postgres:postgres /etc/repmgr/15/repmgr.conf

sudo -u postgres /usr/pgsql-15/bin/repmgr -f /etc/repmgr/15/repmgr.conf primary register
systemctl restart postgresql-15
echo "[LOCAL] ¡Nodo Primario registrado con éxito!"

# =====================================================================
# CONFIGURACIÓN REMOTA DE LOS NODOS SECUNDARIOS (VIA SSH)
# =====================================================================
for i in "${!STANDBY_IPS[@]}"; do
    S_IP=${STANDBY_IPS[$i]}
    S_PASS=${STANDBY_ROOT_PASS[$i]}
    NODE_ID=$((i + 1))
    NODE_NAME="standby_node_$i"

    echo -e "\n[REMOTO] Conectando y configurando Nodo Standby #$i en la IP: $S_IP..."

    # Comando SSH masivo encapsulado
    sshpass -p "$S_PASS" ssh -o StrictHostKeyChecking=no root@$S_IP "
        set -e
        systemctl stop firewalld || true
        systemctl disable firewalld || true

        dnf install -y https://postgresql.org
        dnf install -y nano postgresql15 postgresql15-server postgresql15-contrib repmgr_15

        echo 'postgres:$PASS_REPMGR' | chpasswd

        # Réplica del archivo .pgpass remoto
        mkdir -p /var/lib/pgsql/
        cat <<EOF2 > /var/lib/pgsql/.pgpass
$IP_PRIMARY:5432:repmgr:repmgr:$PASS_REPMGR
$IP_PRIMARY:5432:postgres:postgres:$PASS_REPMGR
$S_IP:5432:repmgr:repmgr:$PASS_REPMGR
$S_IP:5432:postgres:postgres:$PASS_REPMGR
EOF2
        chown postgres:postgres /var/lib/pgsql/.pgpass
        chmod 600 /var/lib/pgsql/.pgpass

        systemctl stop postgresql-15 || true
        if [ -d '$DATA_DIR' ]; then
            rm -rf ${DATA_DIR}/*
        fi

        mkdir -p /etc/repmgr/15/
        cat <<EOF3 > /etc/repmgr/15/repmgr.conf
node_id=$NODE_ID
node_name='$NODE_NAME'
conninfo='host=$S_IP user=repmgr dbname=repmgr password=$PASS_REPMGR'
data_directory='$DATA_DIR'
use_replication_slots=yes
log_level='INFO'
priority=$((100 - NODE_ID))
EOF3
        chown postgres:postgres /etc/repmgr/15/repmgr.conf

        echo 'Clonando base de datos desde el Primario de forma remota...'
        sudo -u postgres /usr/pgsql-15/bin/repmgr -h $IP_PRIMARY -U repmgr -d repmgr -f /etc/repmgr/15/repmgr.conf standby clone --fast-checkpoint

        systemctl daemon-reload
        systemctl enable postgresql-15
        systemctl start postgresql-15

        sudo -u postgres /usr/pgsql-15/bin/repmgr -f /etc/repmgr/15/repmgr.conf standby register
    "
    echo "[REMOTO] ¡Nodo Standby #$i ($S_IP) acoplado con éxito!"
done

# =====================================================================
# VERIFICACIÓN FINAL DEL CLUSTER DESDE EL MAESTRO
# =====================================================================
echo -e "\n============================================================"
echo " ESTADO FINAL DEL CLUSTER"
echo "============================================================"
sudo -u postgres /usr/pgsql-15/bin/repmgr -f /etc/repmgr/15/repmgr.conf cluster show
