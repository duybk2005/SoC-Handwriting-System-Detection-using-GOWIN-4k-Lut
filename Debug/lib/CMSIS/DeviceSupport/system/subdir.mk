################################################################################
# Automatically-generated file. Do not edit!
################################################################################

# Add inputs and outputs from these tool invocations to the build variables 
C_SRCS += \
../lib/CMSIS/DeviceSupport/system/system_gw1ns4c.c 

OBJS += \
./lib/CMSIS/DeviceSupport/system/system_gw1ns4c.o 

C_DEPS += \
./lib/CMSIS/DeviceSupport/system/system_gw1ns4c.d 


# Each subdirectory must supply rules for building sources it contributes
lib/CMSIS/DeviceSupport/system/%.o: ../lib/CMSIS/DeviceSupport/system/%.c lib/CMSIS/DeviceSupport/system/subdir.mk
	@echo 'Building file: $<'
	@echo 'Invoking: GNU Arm Cross C Compiler'
	arm-none-eabi-gcc -mcpu=cortex-m3 -mthumb -O0 -fmessage-length=0 -fsigned-char -ffunction-sections -fdata-sections -g3 -I"C:\Users\diego\OneDrive\Documents\STUDY_MATERIAL\ChuuyenDe\project 1\user_image\lib\CMSIS\CoreSupport\gmd" -I"C:\Users\diego\OneDrive\Documents\STUDY_MATERIAL\ChuuyenDe\project 1\user_image\lib\CMSIS\DeviceSupport\system" -I"C:\Users\diego\OneDrive\Documents\STUDY_MATERIAL\ChuuyenDe\project 1\user_image\lib\StdPeriph_Driver\Includes" -I"C:\Users\diego\OneDrive\Documents\STUDY_MATERIAL\ChuuyenDe\project 1\user_image\template" -std=gnu11 -MMD -MP -MF"$(@:%.o=%.d)" -MT"$@" -c -o "$@" "$<"
	@echo 'Finished building: $<'
	@echo ' '


