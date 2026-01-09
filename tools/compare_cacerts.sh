#!/bin/bash

# Configuration
ATCAS="cacert.pem"   # Your existing file
MOZCAS="https://curl.se/ca/cacert.pem"
TARGET_CAS=(
    "GlobalSign ECC Root CA - R4"
    "GTS Root R1"
    "GTS Root R2"
    "GTS Root R3"
    "GTS Root R4"
    "ISRG Root X1"
    "ISRG Root X2"
    "USERTrust RSA Certification Authority"
    "USERTrust ECC Certification Authority"
)

# Function to extract fingerprint by CN from a specific file
get_fingerprint() {
    local label="$1"
    local file="$2"
    
    # Extract the block and pipe directly to openssl
    awk -v search="$label" '
        BEGIN { found=0 }
        $0 ~ search { found=1 }
        found { print $0 }
        /END CERTIFICATE/ && found { exit }
    ' "$file" | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d'=' -f2
}


if [ ! -f "${ATCAS}" ]; then
    echo "Error: Local file $ATCAS not found."
    exit 1
fi
echo "--- Downloading remote cacert.pem ---"
curl -s -L -o "moz_cacert.pem" "$MOZCAS"
echo "-----------------------------------------------------------------------"
printf "%-40s | %-15s\n" "Certificate Name" "Match Status"
echo "-----------------------------------------------------------------------"
# Main comparison loop
CHANGES_DETECTED=0
for target in "${TARGET_CAS[@]}"; do
    LOCAL_FP=$(get_fingerprint "$target" "$ATCAS")
    REMOTE_FP=$(get_fingerprint "$target" "moz_cacert.pem")
    if [ -z "$REMOTE_FP" ]; then
        printf "%-40s | %-15s\n" "$target" "MISSING REMOTE"
        CHANGES_DETECTED=1
    elif [ -z "$LOCAL_FP" ]; then
        printf "%-40s | %-15s\n" "$target" "MISSING LOCAL"
        CHANGES_DETECTED=1
    elif [ "$LOCAL_FP" == "$REMOTE_FP" ]; then
        printf "%-40s | %-15s\n" "$target" "IDENTICAL"
    else
        printf "%-40s | %-15s\n" "$target" "CHANGED!"
        echo "   Local:  $LOCAL_FP"
        echo "   Remote: $REMOTE_FP"
        CHANGES_DETECTED=1
    fi
done
echo "-----------------------------------------------------------------------"
if [ $CHANGES_DETECTED -eq 1 ]; then
    echo "Warning: Root certificates have changed."
    exit 1
else
    echo "Verification complete. No changes in targeted roots."
    exit 0
fi
