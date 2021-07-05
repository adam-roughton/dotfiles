{ pkgs, ... }:

with pkgs;

# Adapted from https://gist.github.com/ottokruse/1c0f79d51cdaf82a3885f9b532df1ce5
writers.writePython3Bin "aws-console" {
  libraries = [
    python3Packages.boto3
  ];
} ''
import sys
import json
from urllib import parse, request
import boto3
import botocore
import subprocess
import argparse

FEDERATION_URL = "https://signin.aws.amazon.com/federation"


def aws_console(
    args: argparse.Namespace,
) -> None:
    if args.profile:
        try:
            session = boto3.Session(profile_name=args.profile)
        except botocore.exceptions.ProfileNotFound:
            print(f"Could not find profile {args.profile}")
            sys.exit(1)
    else:
        session = boto3.Session()

    creds = session.get_credentials()

    if args.region:
        region = args.region
    else:
        region = session.region_name

    url_credentials = dict(
        sessionId=creds.access_key,
        sessionKey=creds.secret_key,
        sessionToken=creds.token,
    )

    with request.urlopen((
        f"{FEDERATION_URL}"
        "?Action=getSigninToken"
        "&DurationSeconds=43200"
        f"&Session={parse.quote_plus(json.dumps(url_credentials))}"
    )) as res:
        if res.status != 200:
            print(f"Failed to get sign in token: {res.message}")
            sys.exit(1)
        sign_in_token = json.loads(res.read())["SigninToken"]

    if args.service:
        sub_page = parse_service_to_page(args.service)
        destination = parse.quote_plus(
          f"https://console.aws.amazon.com/{sub_page}/home?region={region}"
        )
    else:
        destination = parse.quote_plus(
          f"https://console.aws.amazon.com/console/home?region={region}"
        )

    issuer = parse.quote_plus("https://example.com")

    request_url = (
      f"{FEDERATION_URL}"
      "?Action=login"
      f"&Destination={destination}"
      f"&SigninToken={sign_in_token}"
      f"&Issuer={issuer}"
    )

    subprocess.Popen([
      "qutebrowser",
      "--temp-basedir",
      request_url
    ], start_new_session=True)


def parse_service_to_page(service_id: str):
    if service_id == "emr":
        return "elasticmapreduce"
    elif service_id == "secrets":
        return ""
    else:
        return service_id


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--profile",
        type=str,
        required=False,
        help="the AWS profile to authenticate with.",
    )
    parser.add_argument(
        "--region",
        type=str,
        required=False,
        help="the AWS region to open the console to.",
    )
    parser.add_argument(
        "service",
        type=str,
        help="the AWS service to open",
    )
    args = parser.parse_args()
    return args


if __name__ == '__main__':
    aws_console(parse_args())
''
