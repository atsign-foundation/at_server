#!/usr/bin/python3
"""
Looks for dependency-overrides.yaml file the path specified.
If dependencies are specified, adds the dependencies to dependency_overrides section in pubspec.yaml
This is file is used in GITHub actions to resolve dependencies.
"""
import argparse
import ruamel.yaml
from os import path, stat

# Initialize parser
parser = argparse.ArgumentParser()
# Adding optional argument
parser.add_argument("-p", "--path")

# Read arguments from command line
project_path = parser.parse_args().path
# if project_path does not end with a trailing '/' adds '/'
if not project_path.endswith('/'):
    project_path = project_path + '/'


def main():
    # If file does not exist, exit
    if not path.exists(project_path + 'dependency-overrides.yaml') or not path.exists(project_path + 'pubspec.yaml'):
        print('dependency-overrides.yaml or pubspec.yaml does exist...Exiting')
    # if file is empty, exit.
    if stat(project_path + 'dependency-overrides.yaml').st_size == 0:
        print('dependency-overrides.yaml is empty...Exiting')

    add_dependency_overrides()


def add_dependency_overrides():
    with open(project_path + 'pubspec.yaml', 'r') as pubspec:
        yaml_map = ruamel.yaml.round_trip_load(pubspec, preserve_quotes=True)

    with open(project_path + 'dependency-overrides.yaml', 'r') as dependency_overrides_map:
        dependency_map = ruamel.yaml.round_trip_load(dependency_overrides_map, preserve_quotes=True)

    # If pubpsec.yaml contains dependency_overrides section,
    # update the existing dependency_overrides section
    if 'dependency_overrides' in yaml_map:
        yaml_map['dependency_overrides'].update(dependency_map)
    else:
        yaml_map['dependency_overrides'] = dependency_map

    with open(project_path + 'pubspec.yaml', 'w') as file:
        ruamel.yaml.round_trip_dump(yaml_map, file, explicit_start=True)
    file.close()


if __name__ == '__main__':
    main()
