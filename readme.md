# NOVLPD01-MAC

> [!NOTE]
> This is an App which acts as a driver for the Novation Launchpad Mk1 (the first ever Launchpad from 2009).
>
> I am **not** affiliated with Novation and this is purely a passion project

## Why does this exist?

The Launchpad Mk1 does not classify as a USB-MIDI Device. It uses proprietary messages sent from the host which uses the official *Novation USB Driver*. 

The official Novation USB Driver does not support modern macOS, which is why I build this open-source driver-app instead. Its fully native to *Apple-Silicon* and is running silently in the background.