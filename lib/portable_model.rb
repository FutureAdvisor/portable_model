require 'portable_model/version'
require 'portable_model/active_record'

# Include PortableModel in any ActiveRecord model to enable exporting and
# importing the model's records.
#
module PortableModel

  def self.included(base)
    base.extend(ClassMethods)
  end

  # Export the record to a hash.
  #
  def export_to_hash
    self.class.start_exporting do |exported_records|
      # If the record had already been exported during the current session, use
      # the result of that previous export.
      record_id = "#{self.class.table_name}_#{id}"
      record_hash = exported_records[record_id]

      unless record_hash
        # Export portable attributes.
        record_hash = self.class.portable_attributes.inject({}) do |hash, attr_name|
          hash[attr_name] = attributes[attr_name]
          hash
        end

        # Include the exported attributes of portable associations.
        self.class.portable_associations.inject(record_hash) do |hash, assoc_name|
          assoc = self.__send__(assoc_name)
          hash[assoc_name] = assoc.export_portable_association if assoc
          hash
        end

        exported_records[record_id] = record_hash
      end

      record_hash
    end
  end

  # Export the record to a YAML file.
  #
  def export_to_yml(filename)
    Pathname.new(filename).open('w') do |out|
      YAML::dump(export_to_hash, out)
    end
  end

  # Export values from the record's association.
  #
  def export_from_association(assoc_name)
    self.__send__(assoc_name).export_portable_association
  end

  # Import values into the record's association.
  #
  def import_into_association(assoc_name, assoc_value)
    assoc = self.__send__(assoc_name)
    if assoc
      assoc.import_portable_association(assoc_value)
    else
      assoc_reflection = self.class.reflect_on_association(assoc_name.to_sym)
      raise 'nil can only be handled for direct has_one associations' unless assoc_reflection.macro == :has_one && !assoc_reflection.is_a?(ActiveRecord::Reflection::ThroughReflection)
      assoc = ActiveRecord::Associations::HasOneAssociation.new(self, assoc_reflection)
      assoc.import_portable_association(assoc_value)
      association_instance_set(assoc_reflection.name, assoc.target.nil? ? nil : assoc)
    end
  end

  module ClassMethods

    # Import a record from a hash.
    #
    def import_from_hash(record_hash)
      raise ArgumentError.new('specified argument is not a hash') unless record_hash.is_a?(Hash)

      # Override any necessary attributes before importing.
      record_hash.merge!(overridden_imported_attrs)

      if (columns_hash.include?(inheritance_column) &&
          (record_type_name = record_hash[inheritance_column.to_s]) &&
          !record_type_name.blank? &&
          record_type_name != sti_name)
        # The model implements STI and the record type points to a different
        # class; call the method in that class instead.
        compute_type(record_type_name).import_from_hash(record_hash)
      else
        start_importing do |imported_records|
          # If the hash had already been imported during the current session,
          # use the result of that previous import.
          record = imported_records[record_hash.object_id]

          unless record
            transaction do
              # First split out the attributes that correspond to portable
              # associations.
              assoc_attrs = portable_associations.inject({}) do |hash, assoc_name|
                hash[assoc_name] = record_hash.delete(assoc_name) if record_hash.has_key?(assoc_name)
                hash
              end

              # Create a new record.
              record = create!(record_hash)
              puts "Created #{record.class.name} #{record.id}"

              # Import each of the record's associations into the record.
              assoc_attrs.each do |assoc_name, assoc_value|
                record.import_into_association(assoc_name, assoc_value)
              end
            end

            imported_records[record_hash.object_id] = record
          else
            puts "Using #{record.class.name} #{record.id}"
          end

          record
        end
      end
    end

    # Export a record from a YAML file.
    #
    def import_from_yml(filename, additional_attrs = {})
      record_hash = YAML::load_file(filename)
      import_from_hash(record_hash.merge(additional_attrs))
    end

    # Starts an export session and yields a hash of currently exported records
    # in the session to the specified block.
    #
    def start_exporting(&block)
      start_porting(:exported_records, &block)
    end

    # Starts an import session and yields a hash of currently imported records
    # in the session to the specified block.
    #
    def start_importing(&block)
      start_porting(:imported_records, &block)
    end

    # Returns the names of portable attributes, which are any attributes that
    # are not primary or foreign keys.
    #
    def portable_attributes
      columns.reject do |column|
        # TODO: Consider rejecting counter_cache columns as well; this will involve retrieving a has_many association's corresponding belongs_to association to retrieve its counter_cache_column.
        (
          column.primary ||
          column.name.in?(excluded_export_attrs) ||
          (
            column.name.in?(reflect_on_all_associations(:belongs_to).map(&:association_foreign_key)) &&
            !column.name.in?(included_association_keys)
          )
        )
      end.map(&:name).map(&:to_s)
    end

    # Returns names of portable associations, which are has_one and has_many
    # associations that do not go through other associations and that also
    # include PortableModel.
    #
    # Because has_and_belongs_to_many associations are bi-directional, they are
    # not portable.
    #
    def portable_associations
      reflect_on_all_associations.select do |assoc_reflection|
        assoc_reflection.macro.in?([:has_one, :has_many]) &&
          !assoc_reflection.is_a?(ActiveRecord::Reflection::ThroughReflection) &&
          assoc_reflection.klass.include?(PortableModel)
      end.map(&:name).map(&:to_s)
    end

  protected

    # Excludes the specified attributes whenever a record is exported.
    #
    def exclude_attributes_on_export(*attrs)
      excluded_export_attrs.merge(attrs.map(&:to_s))
    end

    # Includes the specified associations' foreign keys (which are normally
    # excluded by default) whenever a record is exported.
    #
    def include_association_keys_on_export(*associations)
      associations.inject(included_association_keys) do |included_keys, assoc|
        assoc_reflection = reflect_on_association(assoc)
        raise ArgumentError.new('can only include foreign keys of belongs_to associations') unless assoc_reflection.macro == :belongs_to
        included_keys << assoc_reflection.association_foreign_key
      end
    end

    # Overrides the specified attributes whenever a record is imported.
    #
    def override_attributes_on_import(attrs)
      attrs.inject(overridden_imported_attrs) do |overridden_attrs, (attr_name, attr_value)|
        overridden_attrs[attr_name.to_s] = attr_value
        overridden_attrs
      end
    end

  private

    def excluded_export_attrs
      @excluded_export_attrs ||= Set.new
    end

    def included_association_keys
      @included_association_keys ||= Set.new
    end

    def overridden_imported_attrs
      @overridden_imported_attrs ||= {}
    end

    def start_porting(storage_identifier)
      # Use thread-local storage to keep track of records that have been
      # ported in the current session. This way, records that are encountered
      # multiple times are represented using the same resulting object.
      is_new_session = Thread.current[storage_identifier].nil?
      Thread.current[storage_identifier] = {} if is_new_session

      begin
        # Yield the hash of records in the current session to the specified block.
        yield(Thread.current[storage_identifier])
      ensure
        Thread.current[storage_identifier] = nil if is_new_session
      end
    end

  end

end
