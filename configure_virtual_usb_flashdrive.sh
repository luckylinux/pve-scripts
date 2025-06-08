#!/bin/bash

# References:
# - https://forum.proxmox.com/threads/virtual-pendrive-on-vm.114143/
# - https://forum.proxmox.com/threads/how-to-add-to-the-boot-order.21424/

# Request user input if action not provided as an Argument
action=${1-""}
while [ "${action}" != "attach" ] && [ "${action}" != "detach" ]
do
    read -p "Enter Action [attach/detach]: " action
done

# Request user input if vmid not provided as an Argument
vmid=${2-""}
while [ -z "${vmid}" ] && [ ! -f "/etc/pve/qemu-server/${vmid}.conf" ]
do
    echo "Virtual Machines on this Host"

    # Just get the ID
    # mapfile -t virtual_machine_ids < <(qm list | tail +2 | awk '{print $1}')
    # for virtual_machine_id in "${virtual_machine_ids[@]}"
    # do
    #     # Only needed if we previously only got the ID
    #     # virtual_machine_name=$(qm config "${virtual_machine_id}" | grep -E ^name: | awk '{print $2}')
    #
    #     # Echo
    #     echo "- ${virtual_machine_id} (${virtual_machine_name})"
    #done

    # Pre-formatted String
    # mapfile -t virtual_machines < <(qm list | tail +2 | awk '{print - $1 ($2)}')
    # for virtual_machine in "${virtual_machines[@]}"
    # do
    #     # Echo
    #     echo "- ${virtual_machine}"
    #done

    # Parsing Configuration Files - MUCH Faster
    mapfile -t virtual_machine_ids < <(find /etc/pve/qemu-server/ -iwholename "*.conf*" | sed -E "s|/etc/pve/qemu-server/([a-zA-Z0-9]+)\.conf|\1|g" | sort)
    for virtual_machine_id in "${virtual_machine_ids[@]}"
    do
        # Get Name
        virtual_machine_name=$(cat /etc/pve/qemu-server/${virtual_machine_id}.conf | grep -E "^name" | head -n1 | sed -E "s|name:\s?([a-zA-Z0-9]+)|\1|g")

        # Echo
        echo "- ${virtual_machine_id} (${virtual_machine_name})"
    done
    read -p "Enter VM ID to attach Virtual USB Drive to: " vmid
done

# Request user input if diskimage not provided as an Argument
diskimage=${3-""}
while [ -z "${diskimage}" ] && [ ! -f "${diskimage}" ]
do
    # List Available Disk Images from Standard Location
    if [[ -d "/var/lib/usbimages" ]]
    then
        echo "Available USB Disk Images"
        mapfile -t usbimages < <(find /var/lib/usbimages -iwholename "*.img")
        for usbimage in "${usbimages[@]}"
        do
            echo -e "\t- ${usbimage}"
        done
    fi

    read -p "Enter Disk Image to use as Virtual USB Drive: " diskimage
done

# Define Drive String (SLOW)
# drive_str="-drive file=${diskimage},if=none,id=drive-usb0,format=raw,cache=none -device usb-storage,id=drive-usb0,drive=drive-usb0,removable=on,serial=0123456789,bootindex=0"

# Define Drive String (FAST)
drive_str="-drive file=${diskimage},if=none,id=drive-usb0,format=raw,cache=none -device nec-usb-xhci,id=xhci -device usb-storage,bus=xhci.0,drive=drive-usb0,removable=on,serial=0123456789,bootindex=0"

if [[ "${action}" == "attach" ]]
then
    # Debug
    # echo "Drive String: ${drive_str}"

    # Check if USB Virtual Drive is already mounted in other VMs
    mapfile -t matches_drive_str < <(grep -ri " ${drive_str}" /etc/pve/qemu-server | awk '{split($0,a,":"); print a[1]}')

    # If any Match was Found
    if [ ${#matches_drive_str[@]} -gt 0 ]
    then
       # Echo
       echo "ERROR: The USB Virtual Drive Image ${diskimage} is already being defined and used by the following Virtual Machine:"
       for match_drive_str in "${matches_drive_str[@]}"
       do
           echo -e "\n- ${match_drive_str}"
       done

       # Abort
       exit 9
    fi

    # Attach to Virtual Machine
    qm set "${vmid}" -args "${drive_str}"

    # Enable Boot
    existing_boot_devices=$(qm config ${vmid} | grep -E "^boot:" | head -n1 | sed -E "s|boot: order=([a-zA-Z0-9,;]+)|\1|")

    # Add Device via QM Monitor Compatible Interface
    # run_command "${vmid}" "drive_add 0 file=${diskimage},if=none,id=drive-usb0,format=raw,cache=none"
    # run_command "${vmid}" "device_add usb-storage,id=drive-usb0,drive=drive-usb0,removable=on"

    # Add "usb0" before the other Devices
    # sed -Ei "s|boot: order=${existing_boot_devices}|boot: order=usb0,${existing_boot_devices}|" /etc/pve/qemu-server/${vmid}.conf
    # qm set "${vmid}" -boot "order=drive-usb0;${existing_boot_devices}"

    # Ask if User wants to reboot into the USB Image
    reboot_into_usb=""
    while [ "${reboot_into_usb}" != "yes" ] && [ "${reboot_into_usb}" != "no" ]
    do
        read -p "Do you want to start/restart the Virtual Machine and boot into USB [yes/no] ? " reboot_into_usb
    done

    if [[ "${reboot_into_usb}" == "yes" ]]
    then
       # Check if Virtual Machine is currently Running
       current_status=$(qm status "${vmid}" | sed -E "s|status:\s?([a-z])|\1|")

       if [[ "${current_status}" == "running" ]]
       then
           # Reboot Virtual Machine
           qm reboot "${vmid}"
       else
           # Start Virtual Machine
           qm start "${vmid}"
       fi
    fi

elif [[ "${action}" == "detach" ]]
then
    # Get existing args String
    existing_args=$(qm config "${vmid}" | grep -E "^args")

    # Debug
    echo "Drive String: ${drive_str}"
    echo "Existing args: ${existing_args}"

    # Check if Drive String exists at all
    if [[ "${existing_args}" =~ "${drive_str}" ]]
    then
        # Replace existing args String
        cleaned_args=$(echo "${existing_args}" | sed -E "s|${drive_str}||g")

        # Remove args: in front
        cleaned_args=$(echo "${cleaned_args}" | sed -E "s|args:(.*)|\1|")

        # Echo
        echo "USB Device is currently Attached to the Virtual Machine"

        # Check if Virtual Machine is currently Running
        current_status=$(qm status "${vmid}" | sed -E "s|status:\s?([a-z])|\1|")

        if [[ "${current_status}" == "running" ]]
        then
            # Echo
            echo "Shutting down Virtual Machine <${vmid}> before continuing to avoid Disk Errors"

            # Shutdown Virtual Machine as otherwise we will start getting a stream of Disk I/O Errors when disconnecting the USB Device
            qm shutdown "${vmid}"
        fi

        # Echo
        echo "Modifying args Parameter for VM ID ${vmid}"
        echo -e "\tOld Value: ${existing_args}"
        echo -e "\tNew Value: ${cleaned_args}"

        # Detach USB Device from Virtual Machine
        # The Disconnection is **Immediate**
        qm set "${vmid}" -args "${cleaned_args}"

        # Echo
        echo "USB Device Disconnected from Virtual Machine ${vmid}"
    else
        # Not found
        echo "WARNING: USB Virtual Drive ${diskimage} could NOT be found for VM ID ${vmid}"
    fi

    # Disable Boot
    existing_boot_devices=$(qm config ${vmid} | grep -E "^boot:" | head -n1 | sed -E "s|boot: order=([a-zA-Z0-9,;]+)|\1|")

    # Cleaned Boot Devices
    cleaned_boot_devices=$(echo "${existing_boot_devices}" | sed -E "s|usb[0-9]+;(.+)|\1|")

    # Remove Device via QM Monitor Compatible Interface
    # run_command "${vmid}" "device_del drive-usb0"
    # run_command "${vmid}" "drive_del drive-usb0"

    # Remove "usb[0-9]" from List
    # sed -Ei "s|boot: order=${existing_boot_devices}|boot: order=${cleaned_boot_devices}|" /etc/pve/qemu-server/${vmid}.conf
    # qm set "${vmid}" -boot "order=${cleaned_boot_devices}"
fi
