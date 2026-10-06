################################################################################
# Automatically-generated file. Do not edit!
################################################################################

# Add inputs and outputs from these tool invocations to the build variables 
C_SRCS += \
../lib/CMSIS/CoreSupport/gmd/core_cm3.c 

OBJS += \
./lib/CMSIS/CoreSupport/gmd/core_cm3.o 

C_DEPS += \
./lib/CMSIS/CoreSupport/gmd/core_cm3.d 


# Each subdirectory must supply rules for building sources it contributes
lib/CMSIS/CoreSupport/gmd/%.o: ../lib/CMSIS/CoreSupport/gmd/%.c lib/CMSIS/CoreSupport/gmd/subdir.mk
	@echo 'Building file: $<'
	@echo 'Invoking: GNU Arm Cross C Compiler'
	arm-none-eabi-gcc -mcpu=cortex-m3 -mthumb -O0 -fmessage-length=0 -fsigned-char -ffunction-sections -fdata-sections -g3 -I"C:\Users\diego\OneDrive\Documents\STUDY_MATERIAL\ChuuyenDe\project 1\user_image\lib\CMSIS\CoreSupport\gmd" -I"C:\Users\diego\OneDrive\Documents\STUDY_MATERIAL\ChuuyenDe\project 1\user_image\lib\CMSIS\DeviceSupport\system" -I"C:\Users\diego\OneDrive\Documents\STUDY_MATERIAL\ChuuyenDe\project 1\user_image\lib\StdPeriph_Driver\Includes" -I"C:\Users\diego\OneDrive\Documents\STUDY_MATERIAL\ChuuyenDe\project 1\user_image\template" -std=gnu11 -MMD -MP -MF"$(@:%.o=%.d)" -MT"$@" -c -o "$@" "$<"
	@echo 'Finished building: $<'
	@echo ' '


