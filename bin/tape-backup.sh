#!/bin/bash

###
# ARCHIVO:
#   tape-backup.sh (20 de Junio de 2012)
#
# LICENCIA:
#   GNU GPL v3 o posterior (www.fsf.org).
#
# AUTOR:
#   Olaf Reitmaier Veracierta (olafrv@gmail.com)
#
# USO:
#   Script para BASH shell de Linux diseñado para el respaldo
#   completo (full) de directorios y bases de datos PostgreSQL
#   en una unidad de cinta localmente instalada.
##

###
# SECCION DE CONFIGURACION
#
# Cambie las variables de esta sección
# para ajustarla a la forma de backup
##

# Version
VERSION="20062012"

# Email del responsable de los respaldos
# (Para que funcione debe tener instalado
# el paquete sendEmail).
MAIL_TO="respaldos@dem.int"
MAIL_FROM="NO-REPLY <no-reply@dem.int>"

# Directorio raiz de tape-backup (instalacion)
TB_DIR="/opt/tape-backup"

# Directorio temporal de archivos
TMP_DIR="/var/tmp/backups"

# Particion donde reside el directorio temporal
# NOTA: Utilice 'df -h' para determinarlo
TMP_PART=/var

# Directorio de restauracion de los respaldos
REST_DIR="$TMP_DIR/restore"

# Directorio del archivo de registro (log)
LOG_DIR="/var/log/tape-backup"

# Porcentaje de espacio libre minimo que debe
# existir en la particion para realizar un 
# respaldo (peor caso)
PORCENTAJE=15

# Dispositivo(s) de cinta destino de los respaldos
# no se usa /dev/st0 porque regresa la cinta después
# de cada operacion sobre la misma, esto evita poder
# crear multiples sesiones en una misma cinta.
DST_TAPE="/dev/nst0"

# Ruta completa a los comandos
TAR="/bin/tar"
TIME="/usr/bin/time -p"
PSQL="/usr/bin/psql"
PGDUMP="/usr/bin/pg_dump"
PGDUMPALL="/usr/bin/pg_dumpall"
MYSQL="/usr/bin/mysql"
MYDUMP="/usr/bin/mysqldump"
GZIP="/bin/gzip"
SMBCLI="/usr/bin/smbclient"
SENDEMAIL="/usr/bin/sendEmail"
SLAPCAT="/usr/sbin/slapcat"
RDIFF="/usr/bin/rdiff-backup"
SCP="/usr/bin/scp"
MAILX=`which mail`

# Raiz del nombre de los archivos temporales de respaldo
DST_TAR_ROOT="tbk"

# Modo de copiado de los respaldos (tape, smb, scp, cp)
if [ -z "$MODE" ]
then
	MODE="scp"
fi

######################## o ###############################

###
# SECCION DE FUNCIONES
#
# No es necesario modificar nada en esta sección,
# a menos que sepa lo que hace!!!
##

###
# FUNCION:
# ctl_cinta
#
# USO:
# Controlador de la unidad de cinta
#
# PARAMETROS:
# $1: Comando: regresar, respaldar, restaurar, expulsar,
# estado, borrar, posicion, final, anterior, siguiente.
# $2: Directorios (respaldar) o directorio (restaurar).
#
# VARIABLES GLOBALES:
# $TAR, $DST_TAPE, $REST_DIR, $DATE_FORMAT
##
function ctl_cinta
{
	CMD=$1
	FILES_OR_DIRS=$2

	if [ -e $DST_TAPE ]
	then
		if [ `mt -f $DST_TAPE status | grep "ONLINE" | wc -l` -eq 0 ]
		then
			echo "clt_cinta: La unidad de cinta no esta encendida o disponible (ONLINE)."
			echo "           Verifique que el cartucho este dentro de la unidad."
			return 1
		fi
	else
		echo "clt_cinta: La unidad de cinta $DST_TAPE no existe."
		return 1
	fi

	if [ "$CMD" == "respaldar" ]
	then
		$TAR cf $DST_TAPE $FILES_OR_DIRS --totals
		return $?

	elif [ "$CMD" == "listar" ]
	then
		$TAR tf $DST_TAPE
		return $?

	elif [ "$CMD" == "restaurar" ]
	then
		CUR_DIR=`pwd`
		cd $REST_DIR
		$TAR xf $DST_TAPE
		ERROR=$?
		cd $CUR_DIR	
		return $ERROR

	elif [ "$CMD" == "expulsar" ]
	then
		mt -f $DST_TAPE rewoffl
		return $?

	elif [ "$CMD" == "estado" ]
	then
		mt -f $DST_TAPE status
		return $?

	elif [ "$CMD" == "borrar" ]
	then
		mt -f $DST_TAPE erase
		return $?

	elif [ "$CMD" == "regresar" ]
	then
		mt -f $DST_TAPE rewind
		return $?

	elif [ "$CMD" == "anterior" ]
	then
		mt -f $DST_TAPE bsf
		return $?

	elif [ "$CMD" == "siguiente" ]
	then
		mt -f $DST_TAPE fsf
		return $?
	else
		echo "ctl_cinta: Comando $CMD desconocido."
		return 1
	fi
}

function tamano
{
  FILE="$1"
	echo "***** Calculando tamaño del archivo '$FILE'."
 	echo ">> "`date $DATE_FORMAT`
	if [ -f "$FILE" ]
	then
    du -h "$FILE"
  else
		echo "El archivo '$FILE' no existe."	
	fi
}

function copiar
{
	if [ "$MODE" == "tape" ]
	then
		echo "***** Copiando (tape) archivo '$FILE' en cinta."
  	echo ">> "`date $DATE_FORMAT`
    ctl_cinta $CMD $FILE
    return $?
	fi

	if [ "$MODE" == "cp" ]
	then    
		echo "***** Copiando (cp) archivo(s) '$FILE' al directorio '$CP_DIR'."
		echo ">> "`date $DATE_FORMAT`
		$TIME cp $FILE $CP_DIR/`basename $FILE`
		return $?
	fi

 
	if [ "$MODE" == "smb" ]
	then
		echo "***** Copiando (smb) archivos '$FILE' al servidor '$SMB_SERVER'."
		echo ">> "`date $DATE_FORMAT`
		$TIME $SMBCLI //$SMB_SERVER/$SMB_RSRC $SMB_PASS -U $SMB_USER -W $SMB_WG -c "\"prompt; lcd ${TMP_DIR}; cd ${SMB_DIR}; put ${FILE}\""
		return $?
	fi

	if [ "$MODE" == "scp" ]
	then    
		echo "***** Copiando (scp) archivo(s) '$FILE' al servidor '$SSH_SERVER' en la ruta '$SSH_DIR'."
    echo ">> "`date $DATE_FORMAT`
		if [ -z "$SSH_USER" ]
		then	
			SSH_USER=`id -u -n`
		fi
		$TIME $SCP -q $FILE $SSH_USER@$SSH_SERVER:$SSH_DIR 2>&1 > /dev/null
		return $?
	fi
}

###
# SECCION DE EJECUCION
#
# No es necesario modificar nada en esta sección,
# a menos que sepa lo que hace!!!
##

# Redireccionamiento de salida(1) y errores(2)
exec 1>>$LOG_DIR/log.txt
exec 2>>$LOG_DIR/log.txt

# Declaración de variables iniciales
START=`date +%s`
DATE_FORMAT="+%Y.%m.%d_%H.%M.%S"
DST_FILES_ROOT=${DST_TAR_ROOT}"_"`date $DATE_FORMAT`
ERRORES=0

# Inicio de ejecucion (Verificación)
echo
echo "***** Inicio."
echo ">> "`date $DATE_FORMAT`
echo

echo "***** Verificando si $TMP_DIR es una particion debe estar montada."
echo ">> "`date $DATE_FORMAT`
echo
if [ `cat /etc/fstab | grep $TMP_DIR | wc -l` -eq 1 ]
then
	if [ `mount | grep $TMP_DIR | wc -l` -eq 0 ]
	then
		echo "***** ERROR FATAL *****"
		echo ">> "`date $DATE_FORMAT`
		echo
		let ERRORES++
	fi
fi

echo "***** Creando directorios $TMP_DIR/* para respaldos."
echo ">> "`date $DATE_FORMAT`
echo
mkdir -p $TMP_DIR
if [ ! -d "$TMP_DIR" ]
then
	echo "***** ERROR FATAL *****"
	echo ">> "`date $DATE_FORMAT`
	echo
	let ERRORES++
	exit 1
fi

echo "***** Creando el directorio de restauracion."
echo ">> "`date $DATE_FORMAT`
echo
mkdir -p $REST_DIR
if [ ! -d "$REST_DIR" ]
then
	echo "***** ERROR FATAL *****"
	echo ">> "`date $DATE_FORMAT`
	echo
	let ERRORES++
	exit 1
fi

echo "***** Creando el directorio de logs"
echo ">> "`date $DATE_FORMAT`
echo
mkdir -p $LOG_DIR
if [ ! -d "$LOG_DIR" ]
then
	echo "***** ERROR FATAL *****"
	echo ">> "`date $DATE_FORMAT`
	echo
	let ERRORES++
	exit 1
fi

echo "***** Verificando espacio disponible en disco"
echo ">> "`date $DATE_FORMAT`
echo
export PORCENTAJE=$PORCENTAJE
if [ `df -P | grep "$TMP_PART$" | wc -l` -eq 1 ]
then
	export PORCENTAJE_LIBRE=`df -P | grep "$TMP_PART$" | awk '{print int($4*100/$2)}'`
else
	export PORCENTAJE_LIBRE=`df -P | grep "\/$" | awk '{print int($4*100/$2)}'`
fi
echo "% LIBRE     = $PORCENTAJE_LIBRE"
echo "% REQUERIDO = $PORCENTAJE"
echo
if [ `expr $PORCENTAJE_LIBRE \<= $PORCENTAJE` -eq 1 ]
then
	echo "***** ERROR *****"
	echo "***** No hay espacio sufienciente en disco *****"
	echo ">> "`date $DATE_FORMAT`
	echo
	let ERRORES++
fi

# Verificando accesos directos a comandos de PostgreSQL
# segun la version instaladas (Debian)
if [ -d /etc/postgresql ]
then 
	for version in `ls /etc/postgresql`
	do
		if [ ! -h /usr/bin/psql$version ]
		then 
			ln -s /usr/lib/postgresql/$version/bin/psql /usr/bin/psql$version
		fi
	done
fi

# Ejecucion del comando requerido
SRC_CMD="$1"
if [ "$1" == "tape" ]
then

	# Ejecutando una operacion especifica sobre la unidad de cinta

	CMD="$2"	

	echo "***** Ejecutando ($2) operacion en la unidad de cinta."
	echo ">> "`date $DATE_FORMAT`

	ctl_cinta "$CMD"
	ERROR=$?; if [ ! $ERROR -eq 0 ]; then echo "**** ERROR ****"; let ERRORES++; fi

	echo

elif [ "$1" == "email" ]
then

	# Enviando por email el archivo de registro (log)

	echo "***** Enviando correo electrónico."
	echo ">> "`date $DATE_FORMAT`
	echo
	if [ `more ${LOG_DIR}/log.txt | grep "ERROR" | wc -l` -eq 0 ]
	then
		msg="OK"
	else
		msg="ERROR"
	fi

	if [ -f "${SENDEMAIL}" ]
	then
		${SENDEMAIL} -f "${MAIL_FROM}" -u "TB $VERSION [$msg]: $2 - "`date $DATE_FORMAT` \
			-t "${MAIL_TO}" -m "Informe de Respaldo.-" -a "$LOG_DIR/log.txt"
	else
		${MAILX} -s "TB $VERSION [$msg]: $2 - "`date $DATE_FORMAT` ${MAIL_TO} < "$LOG_DIR/log.txt"
	fi

elif [ "$1" == "renlog" ]
then

	# Renombrando el archivo de registro (log)

	echo "***** Renombrando archivo de registro."
	echo ">> "`date $DATE_FORMAT`
	echo
	mv "$LOG_DIR/log.txt" ${LOG_DIR}"/"`date $DATE_FORMAT`".bak"

	echo "***** Limpiando archivo de registro."
	echo ">> "`date $DATE_FORMAT`
	echo
	echo "$LOG_DIR/log.txt"

elif [ "$1" == "ldap" ]
then

	# Ejecutando respaldo de directorio LDAP

	CMD="respaldar"
	LABEL=$2

	CP_DIR=$3

	SMB_SERVER=$3
	SMB_RSRC=$4
	SMB_DIR=$5
	SMB_USER=$6
	SMB_PASS=$7
	SMB_WG=$8

	SSH_SERVER=$3
	SSH_DIR=$4
	SSH_USER=$5

	echo "***** Comprimiendo el directorio LDAP."
	echo ">> "`date $DATE_FORMAT`

	FILE="${TMP_DIR}/${DST_FILES_ROOT}_${LABEL}.ldif.gz"

	$TIME $SLAPCAT | $GZIP - > $FILE
	ERROR=$?; if [ ! $ERROR -eq 0 ]; then echo "**** ERROR ****"; let ERRORES++; fi

  echo
	
	tamano $FILE

	echo

	copiar
	ERROR=$?; if [ ! $ERROR -eq 0 ]; then echo "**** ERROR ****"; let ERRORES++; fi

	rm -f $FILE

	echo

elif [ "$1" == "files" ] || [ "$1" == "filesc" ]
then
	
	# Ejecutando el respaldo de archivos

	CMD="respaldar"
	SRC_FILES_OR_DIRS=$2
	LABEL=$3

	CP_DIR=$4

	SMB_SERVER=$4
	SMB_RSRC=$5
	SMB_DIR=$6
	SMB_USER=$7
	SMB_PASS=$8
	SMB_WG=$9

	SSH_SERVER=$4
	SSH_DIR=$5
	SSH_USER=$6

  echo "***** Comprimiendo en disco el(los) archivo(s) '$SRC_FILES_OR_DIRS'."
	echo ">> "`date $DATE_FORMAT`

	FILE="${TMP_DIR}/${DST_FILES_ROOT}_${LABEL}.tar.gz"

	if [ "$1" == "filesc" ] 
	then
		$TIME $TAR cfz $FILE $SRC_FILES_OR_DIRS --ignore-failed-read
	else
		$TIME $TAR cfz $FILE $SRC_FILES_OR_DIRS
	fi

  ERROR=$?; if [ ! $ERROR -eq 0 ]; then echo "**** ERROR ****"; let ERRORES++; fi

  echo
	
	tamano $FILE

	echo

	copiar
	ERROR=$?; if [ ! $ERROR -eq 0 ]; then echo "**** ERROR ****"; let ERRORES++; fi

	rm -f $FILE

	echo

elif [ "$1" == "pgsql" ] || [ "$1" == "pgmeta" ] || [ "$1" == "pgsqlt" ]
then
	# Ejecutando el respaldo de la base de datos

	CMD="respaldar"
	SRC_CLUSTER="$2"
	SRC_BD="$3"
	LABEL="$4"

	CP_DIR=$5

	SMB_SERVER="$5"
	SMB_RSRC="$6"
	SMB_DIR="$7"
	SMB_USER="$8"
	SMB_PASS="$9"
	SMB_WG="${10}"

	SSH_SERVER=$5
	SSH_DIR=$6
	SSH_USER=$7


	if [ `echo $SRC_CLUSTER | grep \. | wc -l` -eq 1 ]
	then
	  pgversion=`echo $SRC_CLUSTER|cut -d"/" -f1`
	  pgcluster=`echo $SRC_CLUSTER|cut -d"/" -f2`
	  pguser=`echo $SRC_CLUSTER|cut -d"/" -f3`
		if [ ! -z $pguser ] && [ ! -e $PGPASSFILE ] && [ ! -e ~/.pgpass ]
		then
		  echo "***** Se ha especificado un usuario pero no existen los archivos "
		  echo "***** definidos por la variable \$PGPASSFILE ni '~/.pgpass'."
			echo ">> "`date $DATE_FORMAT`
			echo "**** ERROR ****"; 
			let ERRORES++;
		fi
	  SRC_PORT=`pg_lsclusters | grep "$pgversion" | grep "$pgcluster" | awk '{print $3}'`
	fi

	FILE_ROOT="${TMP_DIR}/${DST_FILES_ROOT}_${LABEL}_${pgversion}_${pgcluster}"

	echo "***** Exportando y comprimiendo las bases de datos del cluster $pgversion/$pgcluster."
	echo ">> "`date $DATE_FORMAT`
	echo

	if [ "${SRC_BD:0:3}" == "all" ]
	then
		if [ "${SRC_BD:3:1}" == ":" ]
		then
			BD_NO_LIST=`echo $SRC_BD | cut -d":" -f2 | tr "," " "`
		else
			BD_NO_LIST=
		fi
		#BD_LIST=`su - postgres -c "export PGCLUSTER=$pgversion/$pgcluster; ${PSQL} -p $SRC_PORT -l -t" | cut -d"|" -f1 | sed s/\s\s//g | grep -v ^$`
		BD_LIST=`su - postgres -c "export PGCLUSTER=$pgversion/$pgcluster; ${PSQL} -p $SRC_PORT -l -t -x" | grep '^Name[[:space:]]*|[[:space:]]*' | cut -d "|" -f2 | sed s/\s\s//g | grep -v ^$`
	else
		BD_NO_LIST=
		BD_LIST="$SRC_BD"
	fi

	for BD in $BD_LIST
	do

		OMITIR=0
		for BD_NO in $BD_NO_LIST
		do
			if [ "$BD" == "$BD_NO" ]
			then
				echo
				echo "***** No se respalda la base de datos '$BD_NO' (Omision Explicita)."
				echo ">> "`date $DATE_FORMAT`
				OMITIR=1
				break 
			fi
		done
		if [ $OMITIR -eq 1 ]; then continue; fi

		if [ $BD != "template0" ] && [ $BD != "template1" ] 
		then

			TBL=$(su - postgres -c "export PGCLUSTER=$pgversion/$pgcluster; ${PSQL} -p $SRC_PORT -d ${BD} -t -c \\\\dt" | grep -v "^$" | awk '{print $3}')

			if [ "$TBL" != "No relations found." ]
			then 			  
 
				echo
				echo "***** Exportando el esquema de la base de datos '$BD'."
				echo ">> "`date $DATE_FORMAT`

				FILE="${FILE_ROOT}_${BD}_pgschema.sql.gz"

				if [ -z $pguser ]
				then
					$TIME su - postgres -c "export PGCLUSTER=$pgversion/$pgcluster; $PGDUMP -p $SRC_PORT -s $BD" | $GZIP - > $FILE
				else
					export PGCLUSTER=$pgversion/$pgcluster
					$TIME $PGDUMP -U $pguser -w -p $SRC_PORT -s $BD | $GZIP - > $FILE
				fi
				ERROR=$?; if [ ! $ERROR -eq 0 ]; then echo "**** ERROR ****"; let ERRORES++; fi

  			echo
	
				tamano $FILE

				echo
                        
				copiar
				ERROR=$?; if [ ! $ERROR -eq 0 ]; then echo "**** ERROR ****"; let ERRORES++; fi
                          
				rm -f $FILE

				echo
				echo "***** Exportando los registros de la base de datos '$BD'."
				echo ">> "`date $DATE_FORMAT`

				if [ "$SRC_CMD" == "pgsql" ]
				then

					FILE="${FILE_ROOT}_${BD}.sql.gz"

					if [ -z $pguser ]
					then
						$TIME su - postgres -c "export PGCLUSTER=$pgversion/$pgcluster; $PGDUMP -p $SRC_PORT $BD" | $GZIP - > $FILE
					else
						export PGCLUSTER=$pgversion/$pgcluster
						$TIME $PGDUMP -U $pguser -w -p $SRC_PORT $BD | $GZIP - > $FILE
					fi

					ERROR=$?; if [ ! $ERROR -eq 0 ]; then echo "**** ERROR ****"; let ERRORES++; fi

					echo
	
					tamano $FILE

					echo

					copiar
					ERROR=$?; if [ ! $ERROR -eq 0 ]; then echo "**** ERROR ****"; let ERRORES++; fi
		
					rm -f $FILE

				elif [ "$SRC_CMD" == "pgsqlt" ]
				then
					for TB in $TBL
			    do
						echo
						echo "***** Exportando la tabla '$TB' de la base de datos '$BD'."
			      echo ">> "`date $DATE_FORMAT`

						FILE="${FILE_ROOT}_${BD}_${TB}.sql.gz"

	          if [ -z $pguser ]
  	        then
							$TIME su - postgres -c "export PGCLUSTER=$pgversion/$pgcluster; $PGDUMP -p $SRC_PORT -t $TB $BD" | $GZIP - > $FILE
      	    else
        	    export PGCLUSTER=$pgversion/$pgcluster
          	  $TIME $PGDUMP -U $pguser -w -p $SRC_PORT -t $TB $BD | $GZIP - > $FILE
	          fi
	
						ERROR=$?; if [ ! $ERROR -eq 0 ]; then echo "**** ERROR ****"; let ERRORES++; fi

					  echo
	
						tamano $FILE

						echo

						copiar
						ERROR=$?; if [ ! $ERROR -eq 0 ]; then echo "**** ERROR ****"; let ERRORES++; fi
		
						rm -f $FILE

					done
				fi
			else
				echo
				echo "***** No hay tablas en las base de datos '$BD'."
				echo ">> "`date $DATE_FORMAT`				
			fi

			if [ "$SRC_CMD" == "pgmeta" ]
			then
				if [ "$pgversion" != "7.4" ] && [ "$pgversion" != "8.1" ]
				then

					FILE="${FILE_ROOT}_${BD}_meta.sql.gz"

	        if [ -z $pguser ]
          then
						$TIME su - postgres -c "export PGCLUSTER=$pgversion/$pgcluster; $PGDUMPALL -p $SRC_PORT -g" | $GZIP - > $FILE
          else
						export PGCLUSTER=$pgversion/$pgcluster
						$TIME $PGDUMPALL -U $pguser -w -p $SRC_PORT -g | $GZIP - > $FILE
					fi

					ERROR=$?; if [ ! $ERROR -eq 0 ]; then echo "**** ERROR ****"; let ERRORES++; fi

  				echo
		
					tamano $FILE

					echo

					copiar
					ERROR=$?; if [ ! $ERROR -eq 0 ]; then echo "**** ERROR ****"; let ERRORES++; fi
					
					rm -f $FILE
				else
					echo
					echo "***** Imposible respaldar metadatos para las version 7.4 y 8.1 de PostgreSQL con pgdump(all)."
          echo ">> "`date $DATE_FORMAT`
					echo 
				fi
			fi

			echo
		 fi

	done

elif [ "$1" == "mysql" ]
then
	
	# Ejecutando el respaldo de la base de datos

	CMD="respaldar"
	SRC_HOST="$2"
	SRC_PORT="$3"
	SRC_USER="$4"
	SRC_PASS="$5"
	SRC_BD="$6"
	LABEL="$7"

	CP_DIR=$8

	SMB_SERVER="$8"
	SMB_RSRC="$9"
	SMB_DIR="${10}"
	SMB_USER="${11}"
	SMB_PASS="${12}"
	SMB_WG="${13}"

	SSH_SERVER="$8"
	SSH_DIR="$9"
	SSH_USER="${10}"

	echo "***** Exportando y comprimiendo la(s) base(s) de datos al disco duro."
	echo ">> "`date $DATE_FORMAT`
	echo

	if [ "$SRC_BD" == "all" ]
	then
		BD_LIST=`${MYSQL} -u $SRC_USER --password=$SRC_PASS -h $SRC_HOST --protocol=TCP -P $SRC_PORT -e "show databases" 2>&1 | grep "\|" | grep -v "Database"`
	else
		BD_LIST="$SRC_BD"
	fi

	for BD in $BD_LIST
	do
		echo
		echo "***** Exportando la base de datos '$BD'."
		echo ">> "`date $DATE_FORMAT`

		FILE="${TMP_DIR}/${DST_FILES_ROOT}_${LABEL}_${BD}.sql.gz"

		$TIME $MYDUMP -R -u $SRC_USER --password=$SRC_PASS -h $SRC_HOST --protocol=TCP -P $SRC_PORT $BD | $GZIP - > $FILE
		ERROR=$?; if [ ! $ERROR -eq 0 ]; then echo "**** ERROR ****"; let ERRORES++; fi

	  echo
	
		tamano $FILE

		echo

		copiar
		ERROR=$?; if [ ! $ERROR -eq 0 ]; then echo "**** ERROR ****"; let ERRORES++; fi

		rm -f $FILE

	done

else

	echo "***** ERROR: OPCION '$1' DESCONOCIDA."
	echo ">> "`date $DATE_FORMAT`
	echo
	let ERRORES++
	exit 1

fi


echo "***** Imprimiendo fecha y hora de finalizacion."
echo ">> "`date $DATE_FORMAT`
echo

if [ ! $ERRORES -eq 0 ]
then
	echo "***************************"
	echo "***************************"
	echo "     HUBO $ERRORES ERROR(ES)  "
	echo "***************************"
	echo "***************************"
	echo " >> "`date $DATE_FORMAT`
	echo "***************************"
	echo "***************************"
fi
echo

echo "***** Imprimiento tiempo total de ejecucion."
echo -n ">> "

FINISH=`date +%s`
DIFF=`expr $FINISH - $START`
HRS=`expr $DIFF / 3600`
MIN=`expr $DIFF % 3600 / 60`
SEC=`expr $DIFF % 3600 % 60`

echo -n "$HRS hora(s). "
echo -n "$MIN minuto(s). "
echo "$SEC segundo(s)."
echo

######################## o ###############################
