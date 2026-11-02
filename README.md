# PuenteVR

Ver la pantalla de la PC en el iPhone (visor VR de cartón) y mover la cámara de los juegos con la cabeza.

## Partes
- `PuenteVR/` y `project.yml`: la app del iPhone (se compila con GitHub Actions).
- `pc/puente_vr.py`: el puente que corre en la PC con Windows.

## En la PC
1. `winget install Gyan.FFmpeg` (una sola vez; después abrí otra ventana cmd).
2. En la carpeta `pc`: `py puente_vr.py`
3. Si Windows pregunta por el Firewall: Permitir acceso (redes privadas).

## En el iPhone
1. La PC y el iPhone en la misma red Wi-Fi (mejor de 5 GHz).
2. Abrí PuenteVR. Si aparece "PC encontrada", ya está la IP. Si no, escribí la IP que muestra `puente_vr.py`.
3. Elegí el modo y tocá "Iniciar VR". Ponelo en el visor.

## Modos
- **Juego**: la imagen queda fija y tu cabeza mueve el mouse de la PC (mirar en el juego).
- **Cine**: la pantalla queda fija en el espacio y mirás alrededor (para ver videos).
- **3D lado a lado (SBS)**: para contenido ya dividido en dos mitades.

## En el visor
- Tocar la pantalla: en Juego pausa/activa la cabeza; en Cine recentra.
- Mantener 1 segundo: volver a los ajustes.
