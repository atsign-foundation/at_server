#!/usr/bin/python3
"""
Generates the config.yaml from the config-base.yaml
The default values in the configurations can be overridden by creating an
config-<environment>.properties file
The file accepts an optional parameter <environment>; defaults to production.
Example:
    Generating config.yaml for development.
        create an application properties file as 'config-development.properties'
        Run the generate_config.py passing 'development' as command line argument.
            python3 generate_config.py -e development
"""
import argparse
import yaml
# pip3 install jproperties
from jproperties import Properties

# Initialize parser
parser = argparse.ArgumentParser()
# Adding optional argument
parser.add_argument("-e", "--env", default='production')

# Read arguments from command line
environment = parser.parse_args().env
print('Generating config.yaml for ' + environment + ' environment')

# Read properties file
configs = Properties()
try:
    with open('config-' + environment + '.properties', 'rb') as read_prop:
        configs.load(read_prop)
    read_prop.close()
except OSError as os:
    print('Exception Occurred: ' + os.strerror)
    exit()

try:
    with open("config-base.yaml", "r") as yamlFile:
        yamlMap = yaml.load(yamlFile, Loader=yaml.FullLoader)
        # Loop on each of the property in config properties.
        for key in configs.properties:
            fields = key.split('.')
            temp = yamlMap
            i = 0
            # Iterate into the map until the key is fetched.
            while i < len(fields):
                # Condition is to check if the key in the map is fetched.
                if i == len(fields) - 1:
                    temp[fields[i]] = configs.properties[key]
                    break
                temp = yamlMap[fields[i]]
                i = i + 1
        yamlFile.close()
except OSError as os:
    print('Exception Occurred: ' + os.strerror)

# write to config file.
try:
    with open('config.yaml', 'w') as file:
        documents = yaml.dump(yamlMap, file)
        print('Generated config.yaml file for ' + environment + ' environment successfully.')
    file.close()
except OSError as os:
    print('Exception occurred: ' + os.filename + ' ' + os.strerror)
