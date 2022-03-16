#!/usr/bin/env python3
# Based on acme-dns-tiny https://github.com/Trim/acme-dns-tiny
# pylint: disable=multiple-imports
"""ACME client to met DNS challenge and receive TLS certificate"""
import argparse, base64, binascii, configparser, copy, hashlib, json, logging
import os, re, sys, subprocess, time
import requests
# Needs `pip3 install dnspython`
import dns.resolver
# Timing info
from datetime import datetime
start=datetime.now()
# For root domain updates
rootdomain = False

LOGGER = logging.getLogger('acme_certs')
LOGGER.setLevel(logging.DEBUG)

# Exit codes:
# 1 API token not set in env variable
# 2 Adding TXT record failed
# 3 Waited too long for DNS propagation
# 4 Validation failed after multiple retries

# Get API token and account key from environment variables
do_token = os.getenv('DO_KEY')
if do_token == '' :
    print("Digital Ocean API key not defined in env variable DO_KEY")
    sys.exit(1)

# Set base URL for API
do_base = 'https://api.digitalocean.com/v2/'

# Set headers for Digital Ocean
do_headers = {'Content-Type': 'application/json',
              'Authorization': f'Bearer {do_token}'}

def _base64(text):
    """Encodes string as base64 as specified in the ACME RFC."""
    return base64.urlsafe_b64encode(text).decode("utf8").rstrip("=")


def _openssl(command, options, communicate=None):
    """Run openssl command line and raise IOError on non-zero return."""
    openssl = subprocess.Popen(["openssl", command] + options,
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE)
    out, err = openssl.communicate(communicate)
    if openssl.returncode != 0:
        raise IOError("OpenSSL Error: {0}".format(err))
    return out

# pylint: disable=too-many-locals,too-many-branches,too-many-statements
def get_crt(config, log=LOGGER):
    """Get ACME certificate by resolving DNS challenge."""

    def create_txt(domain,keydigest64):
        log.info(do_token)
        log.info('Creating TXT record on Digital Ocean')
        split_domain=domain.split(".",2)
        if rootdomain:
            chal_domain=split_domain[0]
            base_domain=split_domain[1]+"."+split_domain[2]
        else:
            chal_domain=split_domain[0]+"."+split_domain[1]
            base_domain=split_domain[2]
        api_url = f'{do_base}domains/{base_domain}/records'
        txt_params = {'type' : 'TXT', 'name' : f'{chal_domain}',
            'data' : f'{keydigest64}', 'ttl' : 1800}
        backoff = 1
        while True:
            backoff = backoff * 2
            try:
                txt_add = requests.post(api_url, headers=do_headers, json=txt_params)
            except requests.exceptions.RequestException as error:
                txt_add = error.response
            if backoff > 64:
                log.warning(f'Adding TXT record failed after many retires\n{txt_add.text}')
                sys.exit(2)
            else:
                try:
                    txt_id=txt_add.json()['domain_record']['id']
                    log.info(f'Created TXT record ID: {txt_id}')
                    return(txt_id)
                except KeyError: # API hasn't generated a record
                    log.info(f"Bad response from DO API server, retrying in {backoff}s")
                    log.info(f"{txt_add}")
                    time.sleep(backoff)
                except ValueError:  # if body is empty or not JSON formatted
                    log.info(f"No response from DO API server, retrying in {backoff}s")
                    time.sleep(backoff)

    def test_txt(domain):
        log.info(f'Testing TXT record for {domain}')
        txt_propagated='false'
        wait_time=10
        dns_resolver=dns.resolver.Resolver()
        while txt_propagated == 'false':
            try:
                dnslookup = dns_resolver.resolve(f'{domain}', 'TXT')
            except Exception as e:
                log.info(e)
                dnslookup = ''
            if len(dnslookup):
                log.info(f'TXT record found: {dnslookup}')
                txt_propagated='true'
            else:
                log.info(f'Waiting for {wait_time}')
                time.sleep(wait_time)
                wait_time=wait_time*2
                if wait_time > 320:
                    log.warning('Waited too long for DNS')
                    sys.exit(3)

    def delete_txt(txt_id,domain):
        base_domain=domain.split(".",2)[2]
        log.info('Deleting TXT record')
        api_url = f'{do_base}domains/{base_domain}/records/{txt_id}'

        requests.delete(api_url, headers=do_headers)

    def _send_signed_request(url, payload, extra_headers=None):
        """Sends signed requests to ACME server."""
        nonlocal nonce
        if payload == "":  # on POST-as-GET, final payload has to be just empty string
            payload64 = ""
        else:
            payload64 = _base64(json.dumps(payload).encode("utf8"))
        protected = copy.deepcopy(private_acme_signature)
        protected["nonce"] = nonce or requests.get(acme_config["newNonce"]).headers['Replay-Nonce']
        del nonce
        protected["url"] = url
        if url == acme_config["newAccount"]:
            if "kid" in protected:
                del protected["kid"]
        else:
            del protected["jwk"]
        protected64 = _base64(json.dumps(protected).encode("utf8"))
        signature = _openssl("dgst", ["-sha256", "-sign", config["acmednstiny"]["AccountKeyFile"]],
                             "{0}.{1}".format(protected64, payload64).encode("utf8"))
        jose = {
            "protected": protected64, "payload": payload64, "signature": _base64(signature)
        }
        joseheaders = {'Content-Type': 'application/jose+json'}
        joseheaders.update(adtheaders)
        joseheaders.update(extra_headers or {})
        backoff = 1
        while True:
            backoff = backoff * 2
            try:
                response = requests.post(url, json=jose, headers=joseheaders)
            except requests.exceptions.RequestException as error:
                response = error.response
            if response:
                nonce = response.headers['Replay-Nonce']
                try:
                    return response, response.json()
                except ValueError:  # if body is empty or not JSON formatted
                    return response, json.loads("{}")
            else:
                if backoff > 64:
                    raise RuntimeError("Unable to get response from ACME "
                        "server after multiple retries.")
                else:
                    log.info(f"Can't reach ACME server, retrying in {backoff}s")
                    time.sleep(backoff)

    # main code
    adtheaders = {'User-Agent': 'acme-dns-tiny/2.4',
                  'Accept-Language': config["acmednstiny"].get("Language", "en")}
    nonce = None

    log.info("Find domains to validate from the Certificate Signing Request (CSR) file.")
    csr = _openssl("req", ["-in", config["acmednstiny"]["CSRFile"],
                           "-noout", "-text"]).decode("utf8")
    domains = set()
    common_name = re.search(r"Subject:.*?\s+?CN\s*?=\s*?([^\s,;/]+)", csr)
    if common_name is not None:
        domains.add(common_name.group(1))
    subject_alt_names = re.search(
        r"X509v3 Subject Alternative Name: (?:critical)?\s+([^\r\n]+)\r?\n",
        csr, re.MULTILINE)
    if subject_alt_names is not None:
        for san in subject_alt_names.group(1).split(", "):
            if san.startswith("DNS:"):
                domains.add(san[4:])
    if len(domains) == 0:  # pylint: disable=len-as-condition
        raise ValueError("Didn't find any domain to validate in the provided CSR.")

    log.info("Get private signature from account key.")
    accountkey = _openssl("rsa", ["-in", config["acmednstiny"]["AccountKeyFile"],
                                  "-noout", "-text"])
    signature_search = re.search(r"modulus:\s+?00:([a-f0-9\:\s]+?)\r?\npublicExponent: ([0-9]+)",
                                 accountkey.decode("utf8"), re.MULTILINE)
    if signature_search is None:
        raise ValueError("Unable to retrieve private signature.")
    pub_hex, pub_exp = signature_search.groups()
    pub_exp = "{0:x}".format(int(pub_exp))
    pub_exp = "0{0}".format(pub_exp) if len(pub_exp) % 2 else pub_exp
    # That signature is used to authenticate with the ACME server, it needs to be safely kept
    private_acme_signature = {
        "alg": "RS256",
        "jwk": {
            "e": _base64(binascii.unhexlify(pub_exp.encode("utf-8"))),
            "kty": "RSA",
            "n": _base64(binascii.unhexlify(re.sub(r"(\s|:)", "", pub_hex).encode("utf-8"))),
        },
    }
    private_jwk = json.dumps(private_acme_signature["jwk"], sort_keys=True, separators=(",", ":"))
    jwk_thumbprint = _base64(hashlib.sha256(private_jwk.encode("utf8")).digest())

    log.info("Fetch ACME server configuration from the its directory URL.")
    acme_config = requests.get(config["acmednstiny"]["ACMEDirectory"], headers=adtheaders).json()
    terms_service = acme_config.get("meta", {}).get("termsOfService", "")

    log.info("Register ACME Account to get the account identifier.")
    account_request = {}
    if terms_service:
        account_request["termsOfServiceAgreed"] = True
        log.info(("Terms of service exist and will be automatically agreed if possible, "
                     "you should read them: %s"), terms_service)
    account_request["contact"] = config["acmednstiny"].get("Contacts", "").split(';')
    if account_request["contact"] == [""]:
        del account_request["contact"]

    http_response, account_info = _send_signed_request(acme_config["newAccount"], account_request)
    if http_response.status_code == 201:
        private_acme_signature["kid"] = http_response.headers['Location']
        log.info("  - Registered a new account: '%s'", private_acme_signature["kid"])
    elif http_response.status_code == 200:
        private_acme_signature["kid"] = http_response.headers['Location']
        log.debug("  - Account is already registered: '%s'", private_acme_signature["kid"])

        http_response, account_info = _send_signed_request(private_acme_signature["kid"], "")
    else:
        raise ValueError("Error registering account: {0} {1}"
                         .format(http_response.status_code, account_info))

    log.info("Update contact information if needed.")
    if ("contact" in account_request
            and set(account_request["contact"]) != set(account_info["contact"])):
        http_response, result = _send_signed_request(private_acme_signature["kid"],
                                                     account_request)
        if http_response.status_code == 200:
            log.debug("  - Account updated with latest contact informations.")
        else:
            raise ValueError("Error registering updates for the account: {0} {1}"
                             .format(http_response.status_code, result))

    # new order
    log.info("Request to the ACME server an order to validate domains.")
    new_order = {"identifiers": [{"type": "dns", "value": domain} for domain in domains]}
    http_response, order = _send_signed_request(acme_config["newOrder"], new_order)
    if http_response.status_code == 201:
        order_location = http_response.headers['Location']
        log.debug("  - Order received: %s", order_location)
        if order["status"] != "pending" and order["status"] != "ready":
            raise ValueError("Order status is neither pending neither ready, we can't use it: {0}"
                             .format(order))
    elif (http_response.status_code == 403
          and order["type"] == "urn:ietf:params:acme:error:userActionRequired"):
        raise ValueError(("Order creation failed ({0}). Read Terms of Service ({1}), then follow "
                          "your CA instructions: {2}")
                         .format(order["detail"],
                                 http_response.headers['Link'], order["instance"]))
    else:
        raise ValueError("Error getting new Order: {0} {1}"
                         .format(http_response.status_code, order))

    # complete each authorization challenge
    for authz in order["authorizations"]:
        if order["status"] == "ready":
            log.info("No challenge to process: order is already ready.")
            break

        log.info("Process challenge for authorization: %s", authz)
        # get new challenge
        http_response, authorization = _send_signed_request(authz, "")
        if http_response.status_code != 200:
            raise ValueError("Error fetching challenges: {0} {1}"
                             .format(http_response.status_code, authorization))
        domain = authorization["identifier"]["value"]

        if authorization["status"] == "valid":
            log.info("Skip authorization for domain %s: this is already validated", domain)
            continue
        if authorization["status"] != "pending":
            raise ValueError("Authorization for the domain {0} can't be validated: "
                             "the authorization is {1}.".format(domain, authorization["status"]))

        challenges = [c for c in authorization["challenges"] if c["type"] == "dns-01"]
        if not challenges:
            raise ValueError("Unable to find a DNS challenge to resolve for domain {0}"
                             .format(domain))
        log.info("Install DNS TXT resource for domain: %s", domain)
        challenge = challenges[0]
        keyauthorization = challenge["token"] + "." + jwk_thumbprint
        keydigest64 = _base64(hashlib.sha256(keyauthorization.encode("utf8")).digest())
        log.info(f"Challenge contents: {keydigest64}")
        dnsrr_domain = f'_acme-challenge.{domain}'
        txt_id=create_txt(dnsrr_domain,keydigest64)
        test_txt(dnsrr_domain)

        log.info("Asking ACME server to validate challenge.")
        http_response, result = _send_signed_request(challenge["url"], {})
        if http_response.status_code != 200:
            raise ValueError("Error triggering challenge: {0} {1}"
                             .format(http_response.status_code, result))
        try:
            backoff = 1
            while True:
                backoff = backoff * 2
                http_response, challenge_status = _send_signed_request(challenge["url"], "")
                if http_response.status_code != 200:
                    raise ValueError("Error during challenge validation: {0} {1}".format(
                        http_response.status_code, challenge_status))
                if challenge_status["status"] == "valid":
                    log.info("ACME has verified challenge for domain: %s", domain)
                    break
                elif backoff > 256:
                    log.warning(f"Validation failed after multiple retries")
                    delete_txt(txt_id,dnsrr_domain)
                    sys.exit(4)
                elif challenge_status["status"] == "processing":
                    log.info("Ceritificate isn't ready yet - processing "
                            f", backing off for {backoff}s")
                    time.sleep(backoff)
                elif challenge_status["status"] == "pending":
                    log.info("Ceritificate isn't ready yet - pending "
                            f", backing off for {backoff}s")
                    time.sleep(backoff)
                elif challenge_status["status"] == "invalid":
                    log.info("Validation failed, maybe DNS not propogated "
                            f"yet, backing off for {backoff}s")
                    time.sleep(backoff)
                else:
                    raise ValueError(f"Challenge for domain {domain} did not"
                                     f"pass: {challenge_status}")
        finally:
            delete_txt(txt_id,dnsrr_domain)

    log.info("Request to finalize the order (all challenges have been completed)")
    csr_der = _base64(_openssl("req", ["-in", config["acmednstiny"]["CSRFile"],
                                       "-outform", "DER"]))
    http_response, result = _send_signed_request(order["finalize"], {"csr": csr_der})
    if http_response.status_code != 200:
        raise ValueError("Error while sending the CSR: {0} {1}"
                         .format(http_response.status_code, result))

    while True:
        http_response, order = _send_signed_request(order_location, "")

        if order["status"] == "processing":
            try:
                time.sleep(float(http_response.headers["Retry-After"]))
            except (OverflowError, ValueError, TypeError):
                time.sleep(2)
        elif order["status"] == "valid":
            log.info("Order finalized!")
            break
        else:
            raise ValueError("Finalizing order {0} got errors: {1}".format(
                order_location, order))

    http_response, result = _send_signed_request(
        order["certificate"], "",
        {'Accept': config["acmednstiny"].get("CertificateFormat",
                                             'application/pem-certificate-chain')})
    if http_response.status_code != 200:
        raise ValueError("Finalizing order {0} got errors: {1}"
                         .format(http_response.status_code, result))

    if 'link' in http_response.headers:
        log.info("  - Certificate links given by server: %s", http_response.headers['link'])

    log.info("Certificate signed and chain received: %s", order["certificate"])
    return http_response.text


def main(argv):
    """Parse arguments and get certificate."""
    parser = argparse.ArgumentParser(
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description="Tiny ACME client to get TLS certificate by responding to DNS challenges.",
        epilog="""This script requires access to your private ACME account key and dns server,
so PLEASE READ THROUGH IT (it won't take too long, it's a one-file script) !

Example: requests certificate chain and store it in chain.crt
  python3 acme_certs.py mydomain.example.com"""
    )
    parser.add_argument("-q","--quiet", action="store_const", const=logging.ERROR,
                        help="show only errors on stderr")
    parser.add_argument("-r","--root", action="store_true",
                        help="create a cert for the root of a (sub) domain")
    parser.add_argument("-s","--staging", action="store_true",
                        help="use LetsEncrypt Staging")
    parser.add_argument("-t","--testing", action="store_true",
                        help="print timing info for testing")
    parser.add_argument("-v","--verbose", action="store_const", const=logging.DEBUG,
                        help="show all debug informations on stderr")
    parser.add_argument("-z","--zerossl", action="store_true",
                        help="use ZeroSSL")
    parser.add_argument("cert_name", help="FQDN of certificate to be generated")
    args = parser.parse_args(argv)

    config = configparser.ConfigParser()

    if args.staging:
        config.read_dict({"acmednstiny":
            {"accountkeyfile": "/gluster/@/api/keys/letsencrypt.key",
            "ACMEDirectory": "https://acme-staging-v02.api.letsencrypt.org/directory"}})
    elif args.zerossl:
        config.read_dict({"acmednstiny":
            {"accountkeyfile": "/gluster/@/api/keys/zerossl.key",
            "ACMEDirectory": "https://acme.zerossl.com/v2/DV90"}})
    else:
        config.read_dict({"acmednstiny":
            {"accountkeyfile": "/gluster/@/api/keys/letsencrypt.key",
            "ACMEDirectory": "https://acme-v02.api.letsencrypt.org/directory"}})

    if args.root:
        global rootdomain
        rootdomain = True
    
    logformat = logging.Formatter("%(asctime)s:%(levelname)s:%(message)s")
    logfile = logging.FileHandler(f'{args.cert_name}.log')
    logfile.setFormatter(logformat)

    LOGGER.addHandler(logfile)

    logstream = logging.StreamHandler()
    logstream.setLevel(args.verbose or args.quiet or logging.INFO)
    logstream.setFormatter(logformat)

    LOGGER.addHandler(logstream)

    # Generate a Certificate Signing Request (CSR) using OpenSSL
    LOGGER.info(f'Creating CSR {args.cert_name}.csr')
    _openssl('req',['-new','-newkey','rsa:2048','-nodes',
        '-out',f'{args.cert_name}.csr','-keyout',f'{args.cert_name}.key',
        '-subj',f'/CN={args.cert_name}'])
    config.set("acmednstiny", "csrfile", f"{args.cert_name}.csr")

    if (set(["csrfile", "acmedirectory"]) - set(config.options("acmednstiny"))):
        raise ValueError("Some required settings are missing.")
    signed_crt = get_crt(config, LOGGER)
    cert_file = open(f'{args.cert_name}.fullchain.pem', 'w')
    cert_file.write(signed_crt)
    cert_file.close()

    LOGGER.info(f'Extracting cert from fullchain')
    _openssl('x509', ['-in',f'{args.cert_name}.fullchain.pem','-outform',
        'PEM','-out',f'{args.cert_name}.cert.pem'])

    LOGGER.info(f'Finished.')
    if args.testing:
        print(f"Got certificate for {args.cert_name} in {datetime.now()-start}")

if __name__ == "__main__":  # pragma: no cover
    main(sys.argv[1:])
