# Gentoo Installer

Automatyczny skrypt instalacyjny **Gentoo Linux** przeznaczony do uruchomienia z **Ubuntu Live CD/USB** na maszynie wirtualnej (VirtualBox, QEMU/KVM, VMware).

Po zakończeniu instalacji system zawiera:
- **Gentoo Linux** – system bazowy z profilem `desktop/plasma/systemd`
- **KDE Plasma** – pełne środowisko graficzne
- **systemd** – system init
- **SDDM** – menedżer logowania
- **NetworkManager** – zarządzanie siecią
- Użytkownik **lukasz** (hasło: `666`)

---

## Wymagania

| Wymaganie | Minimum |
|-----------|---------|
| RAM       | 4 GB (zalecane 8 GB) |
| Dysk      | 40 GB (zalecane 60+ GB) |
| CPU       | 2 rdzenie (zalecane 4+) |
| Sieć      | Wymagane połączenie internetowe |
| System    | Ubuntu Live (dowolna wersja LTS) |

---

## Szybki start

1. Uruchom maszynę wirtualną z **Ubuntu Live ISO** (bez instalacji Ubuntu).
2. Otwórz terminal.
3. Pobierz skrypt:
   ```bash
   wget https://raw.githubusercontent.com/DudaLuk/Gentoo_instaler/main/install_gentoo.sh
   ```
4. Uruchom jako root:
   ```bash
   sudo bash install_gentoo.sh
   ```
   Skrypt automatycznie wykryje dysk. Możesz też podać dysk ręcznie:
   ```bash
   sudo bash install_gentoo.sh /dev/sda
   # lub dla QEMU/KVM:
   sudo bash install_gentoo.sh /dev/vda
   ```
5. Po zakończeniu instalacji (zwykle 2–4 godziny zależnie od sprzętu) uruchom ponownie:
   ```bash
   reboot
   ```

---

## Co robi skrypt krok po kroku

1. **Partycjonuje dysk** – automatycznie wykrywa tryb UEFI/BIOS i tworzy odpowiedni układ partycji:
   - *UEFI*: partycja EFI (FAT32) + swap + root (ext4)
   - *BIOS/Legacy*: partycja BIOS boot + /boot (ext4) + swap + root (ext4)

2. **Pobiera najnowszy stage3** (`stage3-amd64-systemd`) z oficjalnych serwerów Gentoo.

3. **Rozpakowuje stage3** i konfiguruje środowisko chroot.

4. **Synchronizuje drzewo Portage** i ustawia profil `desktop/plasma/systemd`.

5. **Kompiluje/instaluje jądro** (`gentoo-kernel-bin` – binarne, bez kompilacji).

6. **Instaluje KDE Plasma** wraz z serwerem X, SDDM, NetworkManager i podstawowymi aplikacjami.

7. **Instaluje GRUB** (obsługa UEFI i BIOS) i generuje konfigurację rozruchu.

8. **Konfiguruje system**: hostname, locale (`pl_PL.UTF-8`), strefa czasowa (`Europe/Warsaw`), `/etc/fstab`.

9. **Tworzy użytkownika** `lukasz` z hasłem `666` i uprawnieniami sudo.

---

## Dane dostępowe po instalacji

| Konto  | Hasło  |
|--------|--------|
| root   | `toor` |
| lukasz | `666`  |

---

## Uwagi

- Skrypt każe potwierdzić operację przed skasowaniem danych na dysku.
- Zmienna `VIDEO_CARDS` w `make.conf` jest domyślnie ustawiona na `vmware virtualbox qxl` – dostosuj do swojego środowiska wirtualizacji.
- Czas instalacji zależy głównie od szybkości internetu i procesora. Etap kompilacji KDE Plasma jest najdłuższy.
