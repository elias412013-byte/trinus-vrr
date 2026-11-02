# -*- coding: utf-8 -*-
"""
PuenteVR - lado PC (Windows)

  * Captura la pantalla con ffmpeg y la manda al iPhone por Wi-Fi (video MJPEG por HTTP).
  * Recibe los movimientos de la cabeza del iPhone y mueve el mouse (para mirar en los juegos).
  * Avisa "acá estoy" por la red para que el iPhone encuentre la PC solo.

Uso (en una ventana cmd, en esta carpeta):
    py puente_vr.py

Opciones útiles:
    py puente_vr.py --ancho 800 --fps 30 --calidad 8     (menos datos = menos retraso)
    py puente_vr.py --sens 2500                          (más sensibilidad del mouse)
    py puente_vr.py --invertir-x   /   --invertir-y      (si un eje va al revés)

Requisito: ffmpeg.   Instalar una sola vez:   winget install Gyan.FFmpeg
(después cerrá y abrí otra ventana cmd)
"""
import argparse
import ctypes
import http.server
import math
import os
import shutil
import socket
import socketserver
import subprocess
import sys
import threading
import time

PUERTO_VIDEO = 8081
PUERTO_CABEZA = 5006
PUERTO_BEACON = 5007
ZONA_MUERTA = 0.00003   # radianes por paquete: ignora el "temblor" del sensor

parser = argparse.ArgumentParser(description="PuenteVR - lado PC")
parser.add_argument("--ancho", type=int, default=960, help="ancho del video (default 960)")
parser.add_argument("--fps", type=int, default=30, help="cuadros por segundo (default 30)")
parser.add_argument("--calidad", type=int, default=6, help="calidad JPEG: 2 (mejor) a 31 (peor), default 6")
parser.add_argument("--sens", type=float, default=1800.0, help="píxeles de mouse por radián (default 1800)")
parser.add_argument("--invertir-x", action="store_true", help="invierte el eje horizontal")
parser.add_argument("--invertir-y", action="store_true", help="invierte el eje vertical")
args = parser.parse_args()

if os.name != "nt":
    print("Este script es para Windows.")
    sys.exit(1)

user32 = ctypes.windll.user32
try:
    user32.SetProcessDPIAware()
except Exception:
    pass
ANCHO_PANTALLA = user32.GetSystemMetrics(0)
ALTO_PANTALLA = user32.GetSystemMetrics(1)


def buscar_ffmpeg():
    aqui = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ffmpeg.exe")
    if os.path.exists(aqui):
        return aqui
    return shutil.which("ffmpeg")


FFMPEG = buscar_ffmpeg()
if not FFMPEG:
    print("No encontré ffmpeg.")
    print("Instalalo con:   winget install Gyan.FFmpeg")
    print("y después cerrá esta ventana y abrí otra.")
    input("Apretá Enter para salir")
    sys.exit(1)


# ---------------------------------------------------------------- video
class CajaDeCuadros:
    def __init__(self):
        self.cond = threading.Condition()
        self.ultimo = None
        self.numero = 0


caja = CajaDeCuadros()


def publicar(cuadro):
    with caja.cond:
        caja.ultimo = cuadro
        caja.numero += 1
        caja.cond.notify_all()


def hilo_ffmpeg():
    cmd = [FFMPEG, "-hide_banner", "-loglevel", "error",
           "-fflags", "nobuffer",
           "-f", "gdigrab", "-framerate", str(args.fps),
           "-offset_x", "0", "-offset_y", "0",
           "-video_size", "%dx%d" % (ANCHO_PANTALLA, ALTO_PANTALLA),
           "-draw_mouse", "1", "-i", "desktop",
           "-vf", "scale=%d:-2:flags=fast_bilinear" % args.ancho,
           "-c:v", "mjpeg", "-q:v", str(args.calidad),
           "-flush_packets", "1",
           "-f", "image2pipe", "pipe:1"]
    while True:
        try:
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
        except OSError as e:
            print("No pude iniciar ffmpeg:", e)
            time.sleep(3)
            continue
        buf = bytearray()
        try:
            while True:
                trozo = proc.stdout.read(65536)
                if not trozo:
                    break
                buf += trozo
                while True:
                    ini = buf.find(b"\xff\xd8")
                    if ini < 0:
                        buf.clear()
                        break
                    fin = buf.find(b"\xff\xd9", ini + 2)
                    if fin < 0:
                        if ini > 0:
                            del buf[:ini]
                        break
                    publicar(bytes(buf[ini:fin + 2]))
                    del buf[:fin + 2]
        finally:
            try:
                proc.kill()
            except Exception:
                pass
        print("ffmpeg se detuvo; reinicio en 2 s...")
        time.sleep(2)


class Manejador(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def log_message(self, *a):
        pass

    def do_GET(self):
        try:
            self.connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass
        self.send_response(200)
        self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        print("Cliente de video conectado:", self.client_address[0])
        ultimo = -1
        try:
            while True:
                with caja.cond:
                    while caja.numero == ultimo:
                        caja.cond.wait(timeout=2)
                    cuadro = caja.ultimo
                    ultimo = caja.numero
                self.wfile.write(b"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: %d\r\n\r\n" % len(cuadro))
                self.wfile.write(cuadro)
                self.wfile.write(b"\r\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError):
            pass
        print("Cliente de video desconectado:", self.client_address[0])


class Servidor(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


# ---------------------------------------------------------------- cabeza -> mouse
def mover_mouse(dx, dy):
    user32.mouse_event(0x0001, int(dx), int(dy), 0, 0)   # MOUSEEVENTF_MOVE


def hilo_cabeza():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("0.0.0.0", PUERTO_CABEZA))
    except OSError as e:
        print("No pude abrir el puerto de la cabeza (%d): %s" % (PUERTO_CABEZA, e))
        return
    ultimo = None
    acc_x = 0.0
    acc_y = 0.0
    avisado = False
    signo_x = -1.0 if args.invertir_x else 1.0
    signo_y = -1.0 if args.invertir_y else 1.0
    while True:
        try:
            datos, _ = s.recvfrom(256)
            partes = datos.decode("utf-8").strip().split(",")
        except (OSError, UnicodeDecodeError):
            continue
        if not partes:
            continue
        if partes[0] == "R":
            ultimo = None
            continue
        if partes[0] != "H" or len(partes) < 4:
            continue
        try:
            yaw = float(partes[1])
            pitch = float(partes[2])
            mult = float(partes[3])
        except ValueError:
            continue
        if not avisado:
            avisado = True
            print("Cabeza conectada: moviendo el mouse.")
        if ultimo is None:
            ultimo = (yaw, pitch)
            continue
        dyaw = yaw - ultimo[0]
        while dyaw > math.pi:
            dyaw -= 2 * math.pi
        while dyaw < -math.pi:
            dyaw += 2 * math.pi
        dpitch = pitch - ultimo[1]
        ultimo = (yaw, pitch)
        if abs(dyaw) < ZONA_MUERTA:
            dyaw = 0.0
        if abs(dpitch) < ZONA_MUERTA:
            dpitch = 0.0
        acc_x += dyaw * args.sens * mult * signo_x
        acc_y += -dpitch * args.sens * mult * signo_y
        ix = int(acc_x)
        iy = int(acc_y)
        acc_x -= ix
        acc_y -= iy
        if ix or iy:
            mover_mouse(ix, iy)


# ---------------------------------------------------------------- "acá estoy"
def hilo_beacon():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    while True:
        try:
            s.sendto(b"PUENTEVR", ("255.255.255.255", PUERTO_BEACON))
        except OSError:
            pass
        time.sleep(1.0)


def ips_locales():
    ips = set()
    try:
        t = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        t.connect(("10.255.255.255", 1))
        ips.add(t.getsockname()[0])
        t.close()
    except Exception:
        pass
    try:
        for ip in socket.gethostbyname_ex(socket.gethostname())[2]:
            ips.add(ip)
    except Exception:
        pass
    return sorted(i for i in ips if not i.startswith("127."))


def main():
    print("PuenteVR - lado PC")
    print("Pantalla: %dx%d  ->  video %d px de ancho, %d fps" % (ANCHO_PANTALLA, ALTO_PANTALLA, args.ancho, args.fps))
    print("IP de esta PC (por si el iPhone no la encuentra solo):", ", ".join(ips_locales()) or "?")
    print("Para probar el video en la PC: abrí http://localhost:%d en el navegador" % PUERTO_VIDEO)
    print("Si Windows pregunta por el Firewall, elegí 'Permitir acceso' (redes privadas).")
    print("Cerrá esta ventana (o Ctrl+C) para salir.\n")
    threading.Thread(target=hilo_ffmpeg, daemon=True).start()
    threading.Thread(target=hilo_cabeza, daemon=True).start()
    threading.Thread(target=hilo_beacon, daemon=True).start()
    servidor = Servidor(("0.0.0.0", PUERTO_VIDEO), Manejador)
    try:
        servidor.serve_forever()
    except KeyboardInterrupt:
        print("Chau.")


if __name__ == "__main__":
    main()
